const std = @import("std");
const ex = @import("zigexec");
const t = std.testing;
const support = @import("support.zig");
const Empty = ex.Values(.{});

test "whenAll passes separate arguments and normal then tuple return stays one value" {
    const Add = struct {
        pub fn call(_: @This(), left: i64, flag: bool, right: i64) i64 {
            return left + @as(i64, @intFromBool(flag)) + right;
        }
    };
    const task = ex.whenAll(.{ ex.just(.{ 41, true }), ex.just(.{0}) });
    try t.expectEqual(42, (try task.then(Add, .{}).syncWait(.{})).?[0]);
    const Pair = struct {
        pub fn call(_: @This()) ex.Values(.{ i64, bool }) {
            return .{ 41, true };
        }
    };
    try t.expectEqual(ex.Values(.{ex.Values(.{ i64, bool })}), @TypeOf(ex.just(.{}).then(Pair, .{})).Values);
    try t.expectEqual(Empty, @TypeOf(ex.whenAll(.{})).Values);
}

test "whenAny returns a named tagged union of each branch completion tuple" {
    const task = ex.whenAny(.{ .number = ex.just(.{42}), .text = ex.just(.{@as([]const u8, "hi")}) });
    const Read = struct {
        pub fn call(_: @This(), result: ex.meta.ValueOf(@TypeOf(task))) i64 {
            return switch (result) {
                .number => |values| values[0],
                .text => |values| @intCast(values[0].len),
            };
        }
    };
    try t.expectEqual(42, (try task.then(Read, .{}).syncWait(.{})).?[0]);
    const indexed = (try ex.whenAny(.{ ex.just(.{}), ex.just(.{42}) }).syncWait(.{})).?[0];
    try t.expectEqualStrings("0", @tagName(indexed));
    try t.expectEqual(Empty, @TypeOf(indexed.@"0"));
}

test "whenAny starts every branch cancels losers and first error or stopped wins" {
    const task = ex.whenAny(.{ .pending = support.AwaitStop{}, .winner = ex.just(.{ true, @as(u8, 7) }) });
    const result = (try task.syncWait(.{})).?[0];
    try t.expect(result == .winner);
    try t.expect(result.winner[0]);
    try t.expectEqual(7, result.winner[1]);
    try t.expectError(error.First, ex.whenAny(.{ ex.justError(Empty, error.First), ex.just(.{42}) }).syncWait(.{}));
    try t.expect((try ex.whenAny(.{ ex.justStopped(Empty), ex.justError(Empty, error.Later) }).syncWait(.{})) == null);
    // A losing error does not replace the winner.
    const won = (try ex.whenAny(.{ .ok = ex.just(.{42}), .err = ex.justError(Empty, error.Later) }).syncWait(.{})).?[0];
    try t.expectEqual(42, won.ok[0]);
}

test "whenAny external cancellation drains all pending branches" {
    var stop: ex.StopSource = .{};
    defer stop.deinit();
    _ = stop.requestStop();
    try t.expect((try ex.whenAny(.{ support.AwaitStop{}, support.AwaitStop{} }).syncWait(.{ .stop_token = stop.token() })) == null);
}

test "whenAny observes loser cleanup performed before completion" {
    const Late = struct {
        exited: *bool,
        pub const Values = Empty;
        pub fn Operation(comptime R: type) type {
            return struct {
                exited: *bool,
                receiver: ex.TypedReceiver(Empty, R),
                output: Empty = .{},
                pub fn start(self: *@This()) void {
                    self.exited.* = true;
                    self.receiver.setValue(&self.output);
                }
            };
        }
        pub fn connectInto(self: @This(), out: anytype, receiver: anytype) void {
            out.* = .{ .exited = self.exited, .receiver = .init(receiver) };
        }
    };
    const Check = struct {
        exited: *bool,
        pub fn call(self: @This(), _: anytype) !void {
            try t.expect(self.exited.*);
        }
    };
    var exited = false;
    _ = try ex.whenAny(.{ ex.just(.{42}), Late{ .exited = &exited } }).then(Check, .{&exited}).syncWait(.{});
}

test "whenAny races parallel completions without changing winning payload" {
    const pool = try ex.ThreadPool.init(t.allocator, 4);
    defer pool.deinit();
    const scheduler = pool.getScheduler();
    for (0..100) |_| {
        const result = (try ex.whenAny(.{
            .left = ex.just(.{@as(i64, 123)}).startsOn(scheduler),
            .right = ex.just(.{ @as(u8, 7), true }).startsOn(scheduler),
        }).syncWait(.{})).?[0];
        switch (result) {
            .left => |values| try t.expectEqual(123, values[0]),
            .right => |values| {
                try t.expectEqual(7, values[0]);
                try t.expect(values[1]);
            },
        }
    }
}

test "whenAny waits for all source completions and permits root destruction" {
    const Source = struct {
        const Self = @This();
        published: *support.Event,
        proceed: *support.Event,
        pub const Values = ex.Values(.{i64});
        pub fn Operation(comptime R: type) type {
            return struct {
                source: Self,
                receiver: ex.TypedReceiver(Values, R),
                output: Values = .{42},
                pub fn start(self: *@This()) void {
                    const thread = std.Thread.spawn(.{}, run, .{self}) catch |err| {
                        self.receiver.setError(err);
                        return;
                    };
                    thread.detach();
                }
                fn run(self: *@This()) void {
                    self.source.published.set();
                    self.source.proceed.wait();
                    std.debug.assert(self.output[0] == 42);
                    self.receiver.setValue(&self.output);
                }
            };
        }
        pub fn connectInto(self: @This(), out: anytype, receiver: anytype) void {
            out.* = .{ .source = self, .receiver = .init(receiver) };
        }
    };
    var published: support.Event = .{};
    var proceed: support.Event = .{};
    const task = ex.whenAny(.{
        .source = Source{ .published = &published, .proceed = &proceed },
        .pending = support.AwaitStop{},
    });
    const Capture = struct {
        const Op = ex.Connection(@TypeOf(task), *@This());
        op: *Op,
        called: std.atomic.Value(bool) = .init(false),
        done: support.Event = .{},
        pub fn getEnv(_: *@This()) ex.Env {
            return .{};
        }
        pub fn setValue(self: *@This(), value: *const @TypeOf(task).Values) void {
            defer self.completeOwnership();
            std.debug.assert(value[0].source[0] == 42);
            self.called.store(true, .release);
        }
        pub fn setError(self: *@This(), _: anyerror) void {
            defer self.completeOwnership();
            @panic("unexpected error");
        }
        pub fn setStopped(self: *@This()) void {
            defer self.completeOwnership();
            @panic("unexpected stop");
        }
        fn completeOwnership(self: *@This()) void {
            t.allocator.destroy(self.op);
            self.done.set();
        }
    };
    const Op = Capture.Op;
    const op = try t.allocator.create(Op);
    var capture: Capture = .{ .op = op };
    ex.connectInto(op, task, &capture);
    op.start();
    published.wait();
    const early = capture.called.load(.acquire);
    proceed.set();
    capture.done.wait();
    try t.expect(!early);
    try t.expect(capture.called.load(.acquire));
}

test "whenAny forwards mid-flight external cancellation and drains registrations" {
    var stop: ex.StopSource = .{};
    defer stop.deinit();
    var entered: [2]support.Event = .{ .{}, .{} };
    const Cancel = struct {
        fn run(source: *ex.StopSource, events: *[2]support.Event) void {
            for (events) |*event| event.wait();
            _ = source.requestStop();
        }
    };
    const thread = try std.Thread.spawn(.{}, Cancel.run, .{ &stop, &entered });
    defer thread.join();
    try t.expect((try ex.whenAny(.{
        support.AwaitStop{ .entered = &entered[0] },
        support.AwaitStop{ .entered = &entered[1] },
    }).syncWait(.{ .stop_token = stop.token() })) == null);
}

test "nested whenAll concatenates values while whenAny and tagged union callbacks stay single values" {
    const Choice = union(enum) { number: i64, empty };
    const Make = struct {
        pub fn call(_: @This(), n: i64) Choice {
            return .{ .number = n };
        }
    };
    const Read = struct {
        pub fn call(_: @This(), choice: Choice) i64 {
            return switch (choice) {
                .number => |n| n,
                .empty => 0,
            };
        }
    };
    try t.expectEqual(42, (try ex.just(42).then(Make, .{}).then(Read, .{}).syncWait(.{})).?[0]);
    const task = ex.whenAll(.{
        ex.whenAll(.{ ex.just(20), ex.just(22) }),
        ex.whenAny(.{ .nested = ex.whenAny(.{ .number = ex.just(42) }) }),
    });
    const values = (try task.syncWait(.{})).?;
    try t.expectEqual(20, values[0]);
    try t.expectEqual(22, values[1]);
    try t.expectEqual(42, values[2].nested[0].number[0]);
}
