const std = @import("std");
const ex = @import("zigexec");
const testing = std.testing;

test "split is lazy, executes once, and caches for late subscribers" {
    var calls: usize = 0;
    const Count = struct {
        count: *usize,
        pub fn call(self: @This()) i64 {
            self.count.* += 1;
            return 21;
        }
        fn double(n: i64) i64 {
            return n * 2;
        }
    };
    var shared = try ex.just(.{}).then(Count, .{ .count = &calls }).split(testing.allocator);
    defer shared.deinit();
    try testing.expectEqual(0, calls);
    const result = (try ex.whenAll(.{ shared.sender(), shared.sender().then(ex.Fn(Count.double), .{}) }).syncWait(.{ .allocator = std.testing.allocator })).?;
    try testing.expectEqual(21, result[0]);
    try testing.expectEqual(42, result[1]);
    try testing.expectEqual(21, (try shared.sender().syncWait(.{ .allocator = std.testing.allocator })).?[0]);
    try testing.expectEqual(1, calls);
}

test "shared owners clone explicitly and unstarted state is released" {
    var shared = try ex.just(.{42}).split(testing.allocator);
    var owner = shared.clone();
    shared.deinit();
    defer owner.deinit();
    try testing.expectEqual(42, (try owner.sender().syncWait(.{ .allocator = std.testing.allocator })).?[0]);
    var never_started = try ex.just(.{1}).split(testing.allocator);
    never_started.deinit();
}

test "split caches errors and stopped" {
    var failed = try ex.justError(@Tuple(&.{i64}), error.Broken).split(testing.allocator);
    defer failed.deinit();
    for (0..2) |_| try testing.expectError(error.Broken, failed.sender().syncWait(.{ .allocator = std.testing.allocator }));
    var stopped = try ex.justStopped(@Tuple(&.{})).split(testing.allocator);
    defer stopped.deinit();
    for (0..2) |_| try testing.expectEqual(null, try stopped.sender().syncWait(.{ .allocator = std.testing.allocator }));
}

test "split allocation failure is reported" {
    try testing.expectError(error.OutOfMemory, ex.just(.{}).split(testing.failing_allocator));
}

test "concurrent subscribers share exactly one asynchronous upstream" {
    const pool = try ex.ThreadPool.init(testing.allocator, 4);
    defer pool.deinit();
    var calls = std.atomic.Value(usize).init(0);
    const Work = struct {
        calls: *std.atomic.Value(usize),
        pub fn call(self: @This()) i64 {
            _ = self.calls.fetchAdd(1, .monotonic);
            return 42;
        }
    };
    var shared = try ex.just(.{}).then(Work, .{ .calls = &calls }).startsOn(pool.getScheduler()).split(testing.allocator);
    defer shared.deinit();
    const result = (try ex.whenAll(.{
        shared.sender().startsOn(pool.getScheduler()),
        shared.sender().startsOn(pool.getScheduler()),
        shared.sender().startsOn(pool.getScheduler()),
    }).syncWait(.{ .allocator = std.testing.allocator })).?;
    try testing.expectEqual(42, result[0]);
    try testing.expectEqual(42, result[1]);
    try testing.expectEqual(42, result[2]);
    try testing.expectEqual(1, calls.load(.acquire));
}

test "shared cancellation notifies all subscribers and started operations own their state" {
    const AwaitStop = @import("support.zig").AwaitStop;
    var source: ex.StopSource = .{};
    defer source.deinit();
    var shared = try ex.asSender(AwaitStop{}).split(testing.allocator);
    const sender = ex.whenAll(.{ shared.sender(), shared.sender() }).withStopToken(source.token());
    const Receiver = struct {
        stopped: bool = false,
        pub fn getEnv(_: *@This()) ex.Env {
            return .{ .allocator = std.testing.allocator };
        }
        pub fn setValue(_: *@This(), _: @Tuple(&.{})) void {
            @panic("unexpected value");
        }
        pub fn setError(_: *@This(), _: anyerror) void {
            @panic("unexpected error");
        }
        pub fn setStopped(self: *@This()) void {
            self.stopped = true;
        }
    };
    var receiver: Receiver = .{};
    var operation = ex.connect(sender, &receiver);
    operation.start();
    shared.deinit(); // The active operations now own all references.
    _ = source.requestStop();
    try testing.expect(receiver.stopped);
}
