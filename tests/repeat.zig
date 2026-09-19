const std = @import("std");
const ex = @import("zigexec");
const t = std.testing;
const support = @import("support.zig");

test "repeatEffectUntil performs many inline iterations without recursive stack growth" {
    const Tick = struct {
        count: *usize,
        pub fn call(self: @This()) bool {
            self.count.* += 1;
            return self.count.* == 100_000;
        }
    };
    var count: usize = 0;
    const task = ex.just(.{}).then(Tick, .{&count}).repeatEffectUntil();
    try t.expectEqual(ex.Values(.{}), @TypeOf(task).Values);
    try t.expect((try task.syncWait(.{ .allocator = std.testing.allocator })) != null);
    try t.expectEqual(100_000, count);
}

test "repeatEffect checks cancellation between inline effects and before the first" {
    const Tick = struct {
        count: *usize,
        stop: *ex.StopSource,
        pub fn call(self: @This()) void {
            self.count.* += 1;
            if (self.count.* == 100) _ = self.stop.requestStop();
        }
    };
    var stop: ex.StopSource = .{};
    defer stop.deinit();
    var count: usize = 0;
    const task = ex.just(.{}).then(Tick, .{ &count, &stop }).repeatEffect().withStopToken(stop.token());
    try t.expectEqual(null, try task.syncWait(.{ .allocator = std.testing.allocator }));
    try t.expectEqual(100, count);
    try t.expectEqual(null, try task.syncWait(.{ .allocator = std.testing.allocator }));
    try t.expectEqual(100, count);
}

test "repetition stops immediately on errors or stopped and is lazy" {
    const Fail = struct {
        count: *usize,
        pub fn call(self: @This()) error{Finished}!void {
            self.count.* += 1;
            if (self.count.* == 10) return error.Finished;
        }
    };
    var count: usize = 0;
    const task = ex.just(.{}).then(Fail, .{&count}).repeatEffect();
    try t.expectEqual(0, count);
    try t.expectError(error.Finished, task.syncWait(.{ .allocator = std.testing.allocator }));
    try t.expectEqual(10, count);
    try t.expectEqual(null, try ex.justStopped(ex.Values(.{})).repeatEffect().syncWait(.{ .allocator = std.testing.allocator }));
    try t.expectEqual(null, try ex.justStopped(ex.Values(.{bool})).repeatEffectUntil().syncWait(.{ .allocator = std.testing.allocator }));
    try t.expectError(error.Failed, ex.justError(ex.Values(.{bool}), error.Failed).repeatEffectUntil().syncWait(.{ .allocator = std.testing.allocator }));
}

test "asynchronous repeats hand off drain ownership across completion threads" {
    const Tick = struct {
        count: *usize,
        pub fn call(self: @This(), allocator: std.mem.Allocator) !bool {
            try t.expectEqual(t.allocator.ptr, allocator.ptr);
            self.count.* += 1;
            return self.count.* == 10_000;
        }
    };
    const pool = try ex.ThreadPool.init(t.allocator, 4);
    defer pool.deinit();
    var count: usize = 0;
    const task = ex.readAllocator().startsOn(pool.getScheduler()).then(Tick, .{&count}).repeatEffectUntil();
    try t.expect((try task.syncWait(.{ .allocator = t.allocator })) != null);
    try t.expectEqual(10_000, count);
}

test "repeatEffectUntil supports deferred expression composition" {
    const Tick = struct {
        count: *usize,
        pub fn call(self: @This(), limit: usize) bool {
            self.count.* += 1;
            return self.count.* == limit;
        }
    };
    var count: usize = 0;
    const task = ex.just(@as(usize, 12)).letValue(ex.upstream().then(Tick, .{&count}).repeatEffectUntil(), .{});
    try t.expect((try task.syncWait(.{ .allocator = std.testing.allocator })) != null);
    try t.expectEqual(12, count);
    var stop: ex.StopSource = .{};
    defer stop.deinit();
    _ = stop.requestStop();
    try t.expectEqual(null, try ex.just(.{}).letValue(ex.upstream().repeatEffect(), .{}).withStopToken(stop.token()).syncWait(.{ .allocator = std.testing.allocator }));
}

test "terminal retirement can destroy the repeating connection" {
    const task = ex.just(true).repeatEffectUntil();
    const Op = ex.Connection(@TypeOf(task));
    const Receiver = struct {
        operation: *Op,
        done: bool = false,
        pub fn getEnv(_: *@This()) ex.Env {
            return .{ .allocator = std.testing.allocator };
        }
        pub fn setValue(self: *@This(), _: *const ex.Values(.{})) void {
            _ = self;
        }
        pub fn setFinished(self: *@This()) void {
            t.allocator.destroy(self.operation);
            self.done = true;
        }
        pub fn setError(_: *@This(), _: anyerror) void {
            @panic("unexpected error");
        }
        pub fn setStopped(_: *@This()) void {
            @panic("unexpected stop");
        }
    };
    const operation = try t.allocator.create(Op);
    var receiver: Receiver = .{ .operation = operation };
    operation.* = ex.connect(task, &receiver);
    operation.start();
    try t.expect(receiver.done);
}

test "cancellation reaches an asynchronous effect already waiting for stop" {
    const Cancel = struct {
        source: *ex.StopSource,
        pub fn call(self: @This()) void {
            _ = self.source.requestStop();
        }
    };
    var stop: ex.StopSource = .{};
    defer stop.deinit();
    const task = ex.whenAll(.{
        ex.asSender(support.AwaitStop{}).repeatEffect().withStopToken(stop.token()),
        ex.just(.{}).then(Cancel, .{&stop}),
    });
    try t.expectEqual(null, try task.syncWait(.{ .allocator = std.testing.allocator }));
}

test "asynchronous retirement may destroy a repeating connection" {
    const pool = try ex.ThreadPool.init(t.allocator, 2);
    defer pool.deinit();
    const task = ex.just(true).startsOn(pool.getScheduler()).repeatEffectUntil();
    const Op = ex.Connection(@TypeOf(task));
    const Receiver = struct {
        operation: *Op,
        done: support.Event = .{},
        pub fn getEnv(_: *@This()) ex.Env {
            return .{ .allocator = std.testing.allocator };
        }
        pub fn setValue(self: *@This(), _: *const ex.Values(.{})) void {
            _ = self;
        }
        pub fn setFinished(self: *@This()) void {
            t.allocator.destroy(self.operation);
            self.done.set();
        }
        pub fn setError(_: *@This(), _: anyerror) void {
            @panic("unexpected error");
        }
        pub fn setStopped(_: *@This()) void {
            @panic("unexpected stop");
        }
    };
    const operation = try t.allocator.create(Op);
    var receiver: Receiver = .{ .operation = operation };
    operation.* = ex.connect(task, &receiver);
    operation.start();
    receiver.done.wait();
}
