const std = @import("std");
const ex = @import("zigexec");
const testing = std.testing;
const support = @import("support.zig");
const Empty = support.Empty;
const Ints = support.Ints;
const Capture = support.IntCapture;
const Event = support.Event;
const double = support.double;

test "then supports multi values, void, error unions and runtime function pointers" {
    const Callbacks = struct {
        fn add(a: i32, b: u8) i64 {
            return @as(i64, a) + b;
        }
        fn discard(_: i64) void {}
        fn fail(_: i64) error{Broken}!i64 {
            return error.Broken;
        }
        fn succeed(a: i64) error{Broken}!i64 {
            return a + 1;
        }
        fn voidFail() error{Broken}!void {
            return error.Broken;
        }
        fn voidSuccess() error{Broken}!void {}
    };
    const pointer: *const fn (i64) i64 = &double;
    const result = try ex.just(.{ @as(i32, 20), @as(u8, 1) }).then(ex.Fn(Callbacks.add), .{}).then(ex.Fn(pointer), .{}).syncWait(.{ .allocator = std.testing.allocator });
    try testing.expectEqual(42, result.?[0]);
    try testing.expect((try ex.just(.{1}).then(ex.Fn(Callbacks.discard), .{}).syncWait(.{ .allocator = std.testing.allocator })) != null);
    try testing.expectEqual(2, (try ex.just(.{1}).then(ex.Fn(Callbacks.succeed), .{}).syncWait(.{ .allocator = std.testing.allocator })).?[0]);
    try testing.expectError(error.Broken, ex.just(.{1}).then(ex.Fn(Callbacks.fail), .{}).syncWait(.{ .allocator = std.testing.allocator }));
    try testing.expectError(error.Broken, ex.just(.{}).then(ex.Fn(Callbacks.voidFail), .{}).syncWait(.{ .allocator = std.testing.allocator }));
    try testing.expect((try ex.just(.{}).then(ex.Fn(Callbacks.voidSuccess), .{}).syncWait(.{ .allocator = std.testing.allocator })) != null);
}

test "error and stopped bypass then and letValue" {
    const Never = struct {
        fn transform(_: i64) i64 {
            @panic("then must not run");
        }
        fn chain(_: i64) ex.Just(.{i64}) {
            @panic("letValue must not run");
        }
    };
    try testing.expectError(error.Broken, ex.justError(Ints, error.Broken).then(ex.Fn(Never.transform), .{}).letValue(ex.Fn(Never.chain), .{}).syncWait(.{ .allocator = std.testing.allocator }));
    try testing.expectEqual(null, try ex.justStopped(Ints).then(ex.Fn(Never.transform), .{}).letValue(ex.Fn(Never.chain), .{}).syncWait(.{ .allocator = std.testing.allocator }));
}

test "recovery callbacks and asynchronous recovery senders" {
    const Callbacks = struct {
        fn recover(_: anyerror) i64 {
            return 42;
        }
        fn cancel() i64 {
            return 7;
        }
        fn recoverSender(_: anyerror) ex.Just(.{i64}) {
            return ex.just(.{42});
        }
        fn stoppedSender() ex.Just(.{i64}) {
            return ex.just(.{7});
        }
        fn failedRecovery(_: anyerror) error{RecoveryFailed}!i64 {
            return error.RecoveryFailed;
        }
    };
    try testing.expectEqual(42, (try ex.justError(Ints, error.Broken).uponError(ex.Fn(Callbacks.recover), .{}).syncWait(.{ .allocator = std.testing.allocator })).?[0]);
    try testing.expectEqual(7, (try ex.justStopped(Ints).uponStopped(ex.Fn(Callbacks.cancel), .{}).syncWait(.{ .allocator = std.testing.allocator })).?[0]);
    try testing.expectEqual(42, (try ex.justError(Ints, error.Broken).letError(ex.Fn(Callbacks.recoverSender), .{}).syncWait(.{ .allocator = std.testing.allocator })).?[0]);
    try testing.expectEqual(7, (try ex.justStopped(Ints).letStopped(ex.Fn(Callbacks.stoppedSender), .{}).syncWait(.{ .allocator = std.testing.allocator })).?[0]);
    try testing.expectError(error.RecoveryFailed, ex.justError(Ints, error.Broken).uponError(ex.Fn(Callbacks.failedRecovery), .{}).syncWait(.{ .allocator = std.testing.allocator }));
    try testing.expectEqual(1, (try ex.just(.{1}).uponError(ex.Fn(Callbacks.recover), .{}).uponStopped(ex.Fn(Callbacks.cancel), .{}).letError(ex.Fn(Callbacks.recoverSender), .{}).letStopped(ex.Fn(Callbacks.stoppedSender), .{}).syncWait(.{ .allocator = std.testing.allocator })).?[0]);
}

test "letValue starts dependent asynchronous work and reports factory errors" {
    const pool = try ex.ThreadPool.init(testing.allocator, 2);
    defer pool.deinit();
    const Scheduler = ex.ThreadPool.Scheduler;
    const Chain = struct {
        scheduler: Scheduler,
        pub fn call(self: @This(), value: i64) ex.StartsOn(Scheduler, ex.Just(.{i64})) {
            return ex.just(.{value * 2}).startsOn(self.scheduler);
        }
        fn fail(_: i64) error{FactoryFailed}!ex.Just(.{i64}) {
            return error.FactoryFailed;
        }
    };
    const work = ex.just(.{21}).startsOn(pool.getScheduler()).letValue(Chain, .{ .scheduler = pool.getScheduler() });
    try testing.expectEqual(42, (try work.syncWait(.{ .allocator = std.testing.allocator })).?[0]);
    try testing.expectError(error.FactoryFailed, ex.just(.{1}).letValue(ex.Fn(Chain.fail), .{}).syncWait(.{ .allocator = std.testing.allocator }));
}

test "whenAll flattens heterogeneous tuples in input order and supports zero children" {
    const result = (try ex.whenAll(.{
        ex.just(.{ @as(i32, 3), @as(u8, 4) }),
        ex.just(.{}),
        ex.just(.{true}),
    }).syncWait(.{ .allocator = std.testing.allocator })).?;
    try testing.expectEqual(@Tuple(&.{ i32, u8, bool }), @TypeOf(result));
    try testing.expectEqual(3, result[0]);
    try testing.expectEqual(4, result[1]);
    try testing.expect(result[2]);
    try testing.expect((try ex.whenAll(.{}).syncWait(.{ .allocator = std.testing.allocator })) != null);
    try testing.expectEqual(null, try ex.whenAll(.{ ex.just(.{}), ex.justStopped(Ints) }).syncWait(.{ .allocator = std.testing.allocator }));
    try testing.expectError(error.Broken, ex.whenAll(.{ ex.justStopped(Ints), ex.justError(Ints, error.Broken) }).syncWait(.{ .allocator = std.testing.allocator }));
}

test "bulk processes indices, preserves values and stops on errors" {
    var data: [4]i64 = @splat(0);
    const Fill = struct {
        fn call(index: usize, array: *[4]i64, factor: i64) void {
            array[index] = @as(i64, @intCast(index)) * factor;
        }
        fn fail(index: usize, array: *[4]i64) error{Broken}!void {
            if (index == 2) return error.Broken;
            array[index] += 1;
        }
    };
    const result = (try ex.just(.{ &data, @as(i64, 3) }).bulk(4, ex.Fn(Fill.call), .{}).syncWait(.{ .allocator = std.testing.allocator })).?;
    try testing.expectEqual(&data, result[0]);
    try testing.expectEqualSlices(i64, &.{ 0, 3, 6, 9 }, &data);
    try testing.expectError(error.Broken, ex.just(.{&data}).bulk(4, ex.Fn(Fill.fail), .{}).syncWait(.{ .allocator = std.testing.allocator }));
    try testing.expectEqualSlices(i64, &.{ 1, 4, 6, 9 }, &data);
}

test "letError can recover asynchronously with multiple success values" {
    const pool = try ex.ThreadPool.init(testing.allocator, 1);
    defer pool.deinit();
    const Scheduler = ex.ThreadPool.Scheduler;
    const Values = @Tuple(&.{ i64, bool });
    const Recover = struct {
        scheduler: Scheduler,
        pub fn call(self: @This(), _: anyerror) ex.Just(.{ i64, bool }).StartsOn(Scheduler) {
            return ex.just(.{ @as(i64, 42), true }).startsOn(self.scheduler);
        }
    };
    const result = (try ex.justError(Values, error.Broken).letError(Recover, .{ .scheduler = pool.getScheduler() }).syncWait(.{ .allocator = std.testing.allocator })).?;
    try testing.expectEqual(42, result[0]);
    try testing.expect(result[1]);
}

test "completion may destroy the operation including inline whenAll parent" {
    const sender = ex.whenAll(.{
        ex.just(.{21}).then(ex.Fn(double), .{}),
        ex.just(.{}).startsOn(ex.InlineScheduler{}),
    });
    const Operation = @TypeOf(sender).Operation;
    const Destroy = struct {
        operation: *Operation,
        called: bool = false,
        pub fn getEnv(_: *@This()) ex.Env {
            return .{ .allocator = std.testing.allocator };
        }
        pub fn setValue(self: *@This(), values: Ints) void {
            std.debug.assert(values[0] == 42);
            testing.allocator.destroy(self.operation);
            self.called = true;
        }
        pub fn setError(_: *@This(), _: anyerror) void {
            @panic("unexpected error");
        }
        pub fn setStopped(_: *@This()) void {
            @panic("unexpected stopped");
        }
    };
    const operation = try testing.allocator.create(Operation);
    var receiver: Destroy = .{ .operation = operation };
    operation.* = ex.connect(sender, &receiver);
    operation.start();
    try testing.expect(receiver.called);
}

test "whenAll reports first observed error, not lowest input index" {
    const pool = try ex.ThreadPool.init(testing.allocator, 2);
    defer pool.deinit();
    var entered: Event = .{};
    const LateFailure = struct {
        entered: *Event,
        pub fn call(self: @This(), env: ex.Env) error{Late}!void {
            self.entered.set();
            while (!env.stop_token.stopRequested()) std.Thread.yield() catch {};
            return error.Late;
        }
    };
    const EarlyFailure = struct {
        entered: *Event,
        pub fn call(self: @This()) error{Early}!void {
            self.entered.wait();
            return error.Early;
        }
    };
    const work = ex.whenAll(.{
        ex.readEnv().then(LateFailure, .{ .entered = &entered }).startsOn(pool.getScheduler()),
        ex.schedule(pool.getScheduler()).then(EarlyFailure, .{ .entered = &entered }),
    });
    try testing.expectError(error.Early, work.syncWait(.{ .allocator = std.testing.allocator }));
}
