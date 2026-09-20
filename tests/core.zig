const std = @import("std");
const ex = @import("zigexec");
const testing = std.testing;
const support = @import("support.zig");
const Empty = support.Empty;
const Ints = support.Ints;
const Capture = support.IntCapture;
const Event = support.Event;
const double = support.double;

test "lazy value pipeline" {
    const work = ex.then(ex.just(.{21}), ex.Fn(double), .{});
    try testing.expectEqual(@as(i64, 42), (try ex.syncWait(work, .{ .allocator = std.testing.allocator })).?[0]);
}

test "construct and connect are lazy; operation stays at its connected address" {
    var calls: usize = 0;
    const Callback = struct {
        calls: *usize,
        pub fn call(self: @This(), value: i64) i64 {
            self.calls.* += 1;
            return value + 1;
        }
    };
    const sender = ex.just(.{41}).then(Callback, .{ .calls = &calls });
    var receiver: Capture = .{};
    var operation: ex.Connection(@TypeOf(sender), @TypeOf(&receiver)) = undefined;
    ex.connectInto(&operation, sender, &receiver);
    try testing.expectEqual(0, calls);
    try testing.expectEqual(0, receiver.completions);
    ex.start(&operation);
    try testing.expectEqual(1, calls);
    try testing.expectEqual(1, receiver.completions);
    try testing.expectEqual(42, receiver.values.?[0]);
}

test "all completion channels are distinct including empty success" {
    try testing.expect((try ex.just(.{}).syncWait(.{ .allocator = std.testing.allocator })) != null);
    try testing.expectEqual(null, try ex.justStopped(Empty).syncWait(.{ .allocator = std.testing.allocator }));
    try testing.expectError(error.Broken, ex.justError(Empty, error.Broken).syncWait(.{ .allocator = std.testing.allocator }));
    var receiver: Capture = .{};
    var operation: ex.Connection(@TypeOf(ex.justError(Ints, error.Broken)), @TypeOf(&receiver)) = undefined;
    ex.connectInto(&operation, ex.justError(Ints, error.Broken), &receiver);
    operation.start();
    try testing.expectEqual(error.Broken, receiver.err.?);
    try testing.expectEqual(1, receiver.completions);
    var stopped: Capture = .{};
    var stopped_op: ex.Connection(@TypeOf(ex.justStopped(Ints)), @TypeOf(&stopped)) = undefined;
    ex.connectInto(&stopped_op, ex.justStopped(Ints), &stopped);
    stopped_op.start();
    try testing.expect(stopped.stopped);
    try testing.expectEqual(1, stopped.completions);
}

test "completion may destroy an asynchronous connection" {
    const pool = try ex.ThreadPool.init(testing.allocator, 2);
    defer pool.deinit();
    const sender = ex.whenAll(.{
        ex.just(.{21}).startsOn(pool.getScheduler()).then(ex.Fn(double), .{}),
        ex.schedule(pool.getScheduler()),
    });
    const Destroy = struct {
        const Operation = ex.Connection(@TypeOf(sender), *@This());
        operation: *Operation,
        finished: Event = .{},
        pub fn getEnv(_: *@This()) ex.Env {
            return .{ .allocator = std.testing.allocator };
        }
        pub fn setValue(self: *@This(), values: *const Ints) void {
            defer self.completeOwnership();
            std.debug.assert(values.*[0] == 42);
        }
        fn completeOwnership(self: *@This()) void {
            testing.allocator.destroy(self.operation);
            self.finished.set();
        }
        pub fn setError(self: *@This(), _: anyerror) void {
            defer self.completeOwnership();
            @panic("unexpected error");
        }
        pub fn setStopped(self: *@This()) void {
            defer self.completeOwnership();
            @panic("unexpected stopped");
        }
    };
    const Operation = Destroy.Operation;
    const operation = try testing.allocator.create(Operation);
    var receiver: Destroy = .{ .operation = operation };
    ex.connectInto(operation, sender, &receiver);
    operation.start();
    receiver.finished.wait();
}
