const std = @import("std");
const ex = @import("zigexec");
const support = @import("support.zig");
const t = std.testing;
const Channel = enum { value, err, stopped };

// The receiver itself is in the allocation it destroys. Merely caching a
// receiver pointer before signaling is not sufficient to pass this test.
fn destroyOnCompletion(sender: anytype, comptime expected: Channel) !void {
    const S = @TypeOf(sender);
    const Signal = struct {
        done: support.Event = .{},
        channel: Channel = undefined,
    };
    const Node = struct {
        operation: ex.Connection(S, *@This()) = undefined,
        signal: *Signal,
        pub fn getEnv(_: *@This()) ex.UnstoppableEnv {
            return .{ .allocator = t.allocator };
        }
        fn finish(self: *@This(), channel: Channel) void {
            const signal = self.signal;
            signal.channel = channel;
            t.allocator.destroy(self);
            signal.done.set();
        }
        pub fn setValue(self: *@This(), _: *const S.Values) void {
            self.finish(.value);
        }
        pub fn setError(self: *@This(), _: anyerror) void {
            self.finish(.err);
        }
        pub fn setStopped(self: *@This()) void {
            self.finish(.stopped);
        }
    };
    var signal: Signal = .{};
    const node = try t.allocator.create(Node);
    node.* = .{ .signal = &signal };
    ex.connectInto(&node.operation, sender, node);
    node.operation.start();
    signal.done.wait();
    try t.expectEqual(expected, signal.channel);
}

test "all completion channels may destroy both connection and receiver inline" {
    try destroyOnCompletion(ex.just(true).repeatUntil(), .value);
    try destroyOnCompletion(ex.justError(ex.Values(.{bool}), error.Failed).repeatUntil(), .err);
    try destroyOnCompletion(ex.justStopped(ex.Values(.{bool})).repeatUntil(), .stopped);
    try destroyOnCompletion(ex.just(42).continuesOn(ex.InlineScheduler{}), .value);
    try destroyOnCompletion(ex.whenAll(.{ ex.just(1), ex.just(2) }), .value);
    try destroyOnCompletion(ex.whenAny(.{ ex.just(1), ex.just(2) }), .value);
    var backend: @import("io.zig").Backend = .{};
    try destroyOnCompletion(ex.io.writeSome(&backend, 1, "hello", 0), .value);
}

test "asynchronous forwarding may destroy an embedded receiver" {
    const pool = try ex.ThreadPool.init(t.allocator, 2);
    defer pool.deinit();
    try destroyOnCompletion(ex.just(true).startsOn(pool.getScheduler()).repeatUntil(), .value);
    try destroyOnCompletion(ex.just(42).continuesOn(pool.getScheduler()), .value);
    try destroyOnCompletion(ex.whenAll(.{
        ex.just(1).startsOn(pool.getScheduler()),
        ex.just(2).startsOn(pool.getScheduler()),
    }), .value);
    var shared = try ex.just(42).startsOn(pool.getScheduler()).split(t.allocator);
    defer shared.deinit();
    try destroyOnCompletion(shared.sender(), .value);
}

test "another thread may complete and destroy an operation before start returns" {
    const Source = struct {
        pub const Values = ex.Values(.{});
        pub fn Operation(comptime R: type) type {
            return struct {
                receiver: ex.TypedReceiver(Values, R),
                pub fn start(self: *@This()) void {
                    const worker = std.Thread.spawn(.{}, run, .{self}) catch |err|
                        return self.receiver.setError(err);
                    // Only this local handle is accessed after publication.
                    worker.join();
                }
                fn run(self: *@This()) void {
                    self.receiver.setValue(&.{});
                }
            };
        }
        pub fn connectInto(_: @This(), out: anytype, receiver: anytype) void {
            out.* = .{ .receiver = .init(receiver) };
        }
    };
    try destroyOnCompletion(ex.asSender(Source{}), .value);
}

test "typed never-stop environment eliminates I/O callback storage through adaptors" {
    const Static = struct {
        pub fn getEnv(_: *@This()) ex.UnstoppableEnv {
            return .{};
        }
        pub fn setValue(_: *@This(), _: *const ex.Values(.{usize})) void {}
        pub fn setError(_: *@This(), _: anyerror) void {}
        pub fn setStopped(_: *@This()) void {}
    };
    const Dynamic = struct {
        pub fn getEnv(_: *@This()) ex.Env {
            return .{};
        }
        pub fn setValue(_: *@This(), _: *const ex.Values(.{usize})) void {}
        pub fn setError(_: *@This(), _: anyerror) void {}
        pub fn setStopped(_: *@This()) void {}
    };
    var backend: @import("io.zig").Backend = .{};
    const sender = ex.io.writeSome(&backend, 1, "abc", 0).continuesOn(ex.InlineScheduler{});
    const A = @TypeOf(sender).Operation(*Static);
    const B = @TypeOf(sender).Operation(*Dynamic);
    try t.expectEqual(0, @sizeOf(ex.StopCallbackFor(*Static)));
    try t.expect(@sizeOf(B) >= @sizeOf(A) + @sizeOf(ex.StopCallback));
    var receiver: Static = .{};
    var operation: ex.Connection(@TypeOf(sender), *Static) = undefined;
    ex.connectInto(&operation, sender, &receiver);
    operation.start();
    try t.expectEqual(1, backend.calls);
}

test "literal stop tokens keep environment convenience compatible" {
    const env: ex.Env = .{};
    const dynamic = env.withStopToken(.{});
    try t.expectEqual(ex.Env, @TypeOf(dynamic));
    try t.expect(!dynamic.stop_token.stopPossible());
    const static = env.withStopToken(ex.NeverStopToken{});
    try t.expectEqual(ex.UnstoppableEnv, @TypeOf(static));
    try t.expectEqual(42, (try ex.just(42).syncWait(.{ .stop_token = .{} })).?[0]);
    var stop: ex.StopSource = .{};
    defer stop.deinit();
    _ = stop.requestStop();
    try t.expectEqual(null, try ex.schedule(ex.InlineScheduler{}).syncWait(.{ .stop_token = .{ .source = &stop } }));
}
