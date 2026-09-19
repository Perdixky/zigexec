const std = @import("std");
const ex = @import("zigexec");
const testing = std.testing;
const support = @import("support.zig");
const Empty = support.Empty;
const Ints = support.Ints;
const Capture = support.IntCapture;
const Event = support.Event;
const double = support.double;

test "parallel pipeline" {
    const pool = try ex.ThreadPool.init(testing.allocator, 2);
    defer pool.deinit();
    const result = (try ex.syncWait(ex.whenAll(.{
        ex.startsOn(pool.getScheduler(), ex.then(ex.just(.{21}), ex.Fn(double), .{})),
        ex.startsOn(pool.getScheduler(), ex.just(.{7})),
    }), .{ .allocator = std.testing.allocator })).?;
    try testing.expectEqual(@as(i64, 42), result[0]);
    try testing.expectEqual(@as(i64, 7), result[1]);
}

test "whenAll branches actually overlap on different threads" {
    const pool = try ex.ThreadPool.init(testing.allocator, 2);
    defer pool.deinit();
    var left_entered: Event = .{};
    var right_entered: Event = .{};
    const Branch = struct {
        entered: *Event,
        other_entered: *Event,
        pub fn call(self: @This()) std.Thread.Id {
            self.entered.set();
            self.other_entered.wait();
            return std.Thread.getCurrentId();
        }
    };
    const result = (try ex.whenAll(.{
        pool.getScheduler().schedule().then(Branch, .{ .entered = &left_entered, .other_entered = &right_entered }),
        pool.getScheduler().schedule().then(Branch, .{ .entered = &right_entered, .other_entered = &left_entered }),
    }).syncWait(.{ .allocator = std.testing.allocator })).?;
    try testing.expect(result[0] != result[1]);
    try testing.expect(result[0] != std.Thread.getCurrentId());
    try testing.expect(result[1] != std.Thread.getCurrentId());
}

test "startsOn executes upstream on destination; continuesOn moves downstream only" {
    const first = try ex.ThreadPool.init(testing.allocator, 1);
    defer first.deinit();
    const second = try ex.ThreadPool.init(testing.allocator, 1);
    defer second.deinit();
    const Ids = struct {
        fn current() std.Thread.Id {
            return std.Thread.getCurrentId();
        }
        fn pair(upstream: std.Thread.Id) struct { std.Thread.Id, std.Thread.Id } {
            return .{ upstream, std.Thread.getCurrentId() };
        }
    };
    const ids = (try ex.just(.{}).then(ex.Fn(Ids.current), .{}).startsOn(first.getScheduler()).continuesOn(second.getScheduler()).then(ex.Fn(Ids.pair), .{}).syncWait(.{ .allocator = std.testing.allocator })).?[0];
    try testing.expect(ids[0] != ids[1]);
    try testing.expect(ids[0] != std.Thread.getCurrentId());
    try testing.expect(ids[1] != std.Thread.getCurrentId());
    const caller_ids = (try ex.just(.{}).then(ex.Fn(Ids.current), .{}).continuesOn(first.getScheduler()).then(ex.Fn(Ids.pair), .{}).syncWait(.{ .allocator = std.testing.allocator })).?[0];
    try testing.expectEqual(std.Thread.getCurrentId(), caller_ids[0]);
    try testing.expect(caller_ids[0] != caller_ids[1]);
}

test "continuesOn forwards errors and stopped on target scheduler" {
    const pool = try ex.ThreadPool.init(testing.allocator, 1);
    defer pool.deinit();
    const Ids = struct {
        fn err(_: anyerror) std.Thread.Id {
            return std.Thread.getCurrentId();
        }
        fn stopped() std.Thread.Id {
            return std.Thread.getCurrentId();
        }
    };
    const Values = @Tuple(&.{std.Thread.Id});
    const from_error = (try ex.justError(Values, error.Broken).continuesOn(pool.getScheduler()).uponError(ex.Fn(Ids.err), .{}).syncWait(.{ .allocator = std.testing.allocator })).?[0];
    const from_stop = (try ex.justStopped(Values).continuesOn(pool.getScheduler()).uponStopped(ex.Fn(Ids.stopped), .{}).syncWait(.{ .allocator = std.testing.allocator })).?[0];
    try testing.expect(from_error != std.Thread.getCurrentId());
    try testing.expectEqual(from_error, from_stop);
}

test "runLoop executes on driver thread and rejects work after finish" {
    var loop: ex.RunLoop = .{};
    const runner = try std.Thread.spawn(.{}, ex.RunLoop.run, .{&loop});
    defer runner.join();
    defer loop.finish();
    const Current = struct {
        fn call() std.Thread.Id {
            return std.Thread.getCurrentId();
        }
    };
    const id = (try loop.getScheduler().schedule().then(ex.Fn(Current.call), .{}).syncWait(.{ .allocator = std.testing.allocator })).?[0];
    try testing.expect(id != std.Thread.getCurrentId());
    loop.finish();
    try testing.expectError(error.SchedulerStopped, ex.schedule(loop.getScheduler()).syncWait(.{ .allocator = std.testing.allocator }));
}

test "runLoop can be driven on caller thread with manual receiver" {
    var loop: ex.RunLoop = .{};
    const Receiver = struct {
        loop: *ex.RunLoop,
        called: bool = false,
        pub fn getEnv(_: *@This()) ex.Env {
            return .{ .allocator = std.testing.allocator };
        }
        pub fn setValue(self: *@This(), _: *const Empty) void {
            self.called = true;
            self.loop.finish();
        }
        pub fn setError(_: *@This(), _: anyerror) void {
            @panic("unexpected error");
        }
        pub fn setStopped(_: *@This()) void {
            @panic("unexpected stopped");
        }
    };
    var receiver: Receiver = .{ .loop = &loop };
    var operation = ex.connect(loop.getScheduler().schedule(), &receiver);
    operation.start();
    try testing.expect(!receiver.called);
    loop.run();
    try testing.expect(receiver.called);
}

test "pool allocation failures release resources and zero threads is rejected" {
    try testing.expectError(error.InvalidThreadCount, ex.ThreadPool.init(testing.allocator, 0));
    const Make = struct {
        fn pool(allocator: std.mem.Allocator) !void {
            const p = try ex.ThreadPool.init(allocator, 2);
            defer p.deinit();
            _ = try ex.schedule(p.getScheduler()).syncWait(.{ .allocator = std.testing.allocator });
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Make.pool, .{});
}

test "custom sender and scheduler interoperate with free and fluent algorithms" {
    const Custom = struct {
        pub const Values = Ints;
        pub const Operation = struct {
            receiver: ex.Receiver(Values),
            output: Values = .{21},
            pub fn start(self: *@This()) void {
                self.receiver.setValue(&self.output);
            }
        };
        pub fn connect(_: @This(), receiver: ex.Receiver(Values)) Operation {
            return .{ .receiver = receiver };
        }
    };
    const CustomScheduler = struct {
        pub fn schedule(_: @This()) @TypeOf(ex.just(.{})) {
            return ex.just(.{});
        }
    };
    try testing.expectEqual(42, (try ex.asSender(Custom{}).then(ex.Fn(double), .{}).startsOn(CustomScheduler{}).syncWait(.{ .allocator = std.testing.allocator })).?[0]);
    try testing.expectEqual(42, (try ex.syncWait(ex.then(Custom{}, ex.Fn(double), .{}), .{ .allocator = std.testing.allocator })).?[0]);
}

test "reusing immutable sender builds independent operations under contention" {
    const pool = try ex.ThreadPool.init(testing.allocator, 4);
    defer pool.deinit();
    const sender = ex.whenAll(.{
        ex.just(.{1}).then(ex.Fn(double), .{}).startsOn(pool.getScheduler()),
        ex.just(.{2}).then(ex.Fn(double), .{}).startsOn(pool.getScheduler()),
        ex.just(.{3}).then(ex.Fn(double), .{}).startsOn(pool.getScheduler()),
        ex.just(.{4}).then(ex.Fn(double), .{}).startsOn(pool.getScheduler()),
    });
    for (0..250) |_| {
        const result = (try sender.syncWait(.{ .allocator = std.testing.allocator })).?;
        try testing.expectEqual(2, result[0]);
        try testing.expectEqual(4, result[1]);
        try testing.expectEqual(6, result[2]);
        try testing.expectEqual(8, result[3]);
    }
}

test "scheduler failure overrides stored completion during transfer" {
    var loop: ex.RunLoop = .{};
    loop.finish();
    const scheduler = loop.getScheduler();
    try testing.expectError(error.SchedulerStopped, ex.just(.{1}).continuesOn(scheduler).syncWait(.{ .allocator = std.testing.allocator }));
    try testing.expectError(error.SchedulerStopped, ex.justError(Ints, error.Original).continuesOn(scheduler).syncWait(.{ .allocator = std.testing.allocator }));
    try testing.expectError(error.SchedulerStopped, ex.justStopped(Ints).continuesOn(scheduler).syncWait(.{ .allocator = std.testing.allocator }));
    const Never = struct {
        fn call() void {
            @panic("failed scheduling must not start upstream");
        }
    };
    try testing.expectError(error.SchedulerStopped, ex.just(.{}).then(ex.Fn(Never.call), .{}).startsOn(scheduler).syncWait(.{ .allocator = std.testing.allocator }));
}

test "finish drains jobs queued before run and closes further submissions" {
    var loop: ex.RunLoop = .{};
    var left: Capture = .{};
    var right: Capture = .{};
    var first = ex.connect(ex.just(.{1}).startsOn(loop.getScheduler()), &left);
    var second = ex.connect(ex.just(.{2}).startsOn(loop.getScheduler()), &right);
    first.start();
    second.start();
    loop.finish();
    loop.run();
    try testing.expectEqual(1, left.values.?[0]);
    try testing.expectEqual(2, right.values.?[0]);
    try testing.expectEqual(1, left.completions);
    try testing.expectEqual(1, right.completions);
}
