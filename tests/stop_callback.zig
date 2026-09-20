const std = @import("std");
const ex = @import("zigexec");
const t = std.testing;
const Event = @import("support.zig").Event;
const AwaitStop = @import("support.zig").AwaitStop;
fn increment(ctx: *anyopaque) void {
    const count: *usize = @ptrCast(@alignCast(ctx));
    count.* += 1;
}

test "callbacks invoke once; late registration invokes immediately; null token never invokes" {
    var source: ex.StopSource = .{};
    defer source.deinit();
    var calls: usize = 0;
    var first: ex.StopCallback = .{};
    first.init(source.token(), &calls, increment);
    defer first.deinit();
    try t.expect(source.requestStop());
    try t.expect(!source.requestStop());
    var late: ex.StopCallback = .{};
    late.init(source.token(), &calls, increment);
    defer late.deinit();
    var never: ex.StopCallback = .{};
    never.init(.{}, &calls, increment);
    never.deinit();
    try t.expectEqual(2, calls);
}

test "unregistering prevents invocation, including removing another callback during dispatch" {
    var source: ex.StopSource = .{};
    defer source.deinit();
    var calls: usize = 0;
    var removed: ex.StopCallback = .{};
    removed.init(source.token(), &calls, increment);
    removed.deinit();
    var earlier: ex.StopCallback = .{};
    earlier.init(source.token(), &calls, increment);
    const Remove = struct {
        fn call(ctx: *anyopaque) void {
            const callback: *ex.StopCallback = @ptrCast(@alignCast(ctx));
            callback.deinit();
        }
    };
    var remover: ex.StopCallback = .{};
    remover.init(source.token(), &earlier, Remove.call);
    defer remover.deinit();
    _ = source.requestStop();
    try t.expectEqual(0, calls);
}

test "registration can destroy itself during dispatch and during immediate registration" {
    const SelfDelete = struct {
        callback: ex.StopCallback = .{},
        fn invoke(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.callback.deinit();
            t.allocator.destroy(self);
        }
    };
    var source: ex.StopSource = .{};
    defer source.deinit();
    const first = try t.allocator.create(SelfDelete);
    first.* = .{};
    first.callback.init(source.token(), first, SelfDelete.invoke);
    _ = source.requestStop();
    const second = try t.allocator.create(SelfDelete);
    second.* = .{};
    second.callback.init(source.token(), second, SelfDelete.invoke);
}

test "foreign unregister waits until callback has returned" {
    var source: ex.StopSource = .{};
    defer source.deinit();
    const State = struct {
        entered: Event = .{},
        release: Event = .{},
        completed: std.atomic.Value(bool) = .init(false),
        fn invoke(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.entered.set();
            self.release.wait();
            self.completed.store(true, .release);
        }
        fn request(s: *ex.StopSource) void {
            _ = s.requestStop();
        }
        fn remove(callback: *ex.StopCallback, self: *@This(), removing: *Event) void {
            removing.set();
            callback.deinit();
            std.debug.assert(self.completed.load(.acquire));
        }
    };
    var state: State = .{};
    var callback: ex.StopCallback = .{};
    callback.init(source.token(), &state, State.invoke);
    const requester = try std.Thread.spawn(.{}, State.request, .{&source});
    defer requester.join();
    state.entered.wait();
    var removing: Event = .{};
    const remover = try std.Thread.spawn(.{}, State.remove, .{ &callback, &state, &removing });
    removing.wait();
    state.release.set();
    remover.join();
}

test "registration, removal and stop request races never invoke twice or access freed node" {
    const Race = struct {
        fn request(source: *ex.StopSource) void {
            _ = source.requestStop();
        }
        fn count(ctx: *anyopaque) void {
            const calls: *std.atomic.Value(usize) = @ptrCast(@alignCast(ctx));
            _ = calls.fetchAdd(1, .monotonic);
        }
    };
    for (0..100) |_| {
        var source: ex.StopSource = .{};
        var calls = std.atomic.Value(usize).init(0);
        const requester = try std.Thread.spawn(.{}, Race.request, .{&source});
        const callback = try t.allocator.create(ex.StopCallback);
        callback.* = .{};
        callback.init(source.token(), &calls, Race.count);
        callback.deinit();
        t.allocator.destroy(callback);
        requester.join();
        try t.expect(calls.load(.acquire) <= 1);
        source.deinit();
    }
}

test "callback-driven cancellation propagates through nested graph without polling" {
    var source: ex.StopSource = .{};
    defer source.deinit();
    var added: ex.StopSource = .{};
    defer added.deinit();
    const sender = ex.whenAll(.{
        ex.whenAll(.{ ex.asSender(AwaitStop{}), ex.just(.{}) }),
        ex.just(.{}),
    }).withStopToken(added.token()).withStopToken(source.token());
    const Receiver = struct {
        const Operation = ex.Connection(@TypeOf(sender), *@This());
        operation: *Operation,
        called: bool = false,
        pub fn getEnv(_: *@This()) ex.Env {
            return .{ .allocator = std.testing.allocator };
        }
        pub fn setValue(self: *@This(), _: *const @TypeOf(sender).Values) void {
            defer self.completeOwnership();
            @panic("unexpected value");
        }
        pub fn setError(self: *@This(), _: anyerror) void {
            defer self.completeOwnership();
            @panic("unexpected error");
        }
        pub fn setStopped(self: *@This()) void {
            defer self.completeOwnership();
        }
        fn completeOwnership(self: *@This()) void {
            t.allocator.destroy(self.operation);
            self.called = true;
        }
    };
    const Operation = Receiver.Operation;
    const operation = try t.allocator.create(Operation);
    var receiver: Receiver = .{ .operation = operation };
    ex.connectInto(operation, sender, &receiver);
    operation.start();
    try t.expect(!receiver.called);
    _ = source.requestStop();
    try t.expect(receiver.called);
}

test "callbacks support recursive requests and registration during dispatch" {
    var source: ex.StopSource = .{};
    defer source.deinit();
    const State = struct {
        source: *ex.StopSource,
        calls: usize = 0,
        fn nested(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
        }
        fn invoke(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            std.debug.assert(!self.source.requestStop());
            var callback: ex.StopCallback = .{};
            callback.init(self.source.token(), self, nested);
            callback.deinit();
            self.calls += 1;
        }
    };
    var state: State = .{ .source = &source };
    var callback: ex.StopCallback = .{};
    callback.init(source.token(), &state, State.invoke);
    defer callback.deinit();
    _ = source.requestStop();
    try t.expectEqual(2, state.calls);
}
