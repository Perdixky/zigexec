const std = @import("std");
const ex = @import("zigexec");
const testing = std.testing;
const support = @import("support.zig");
const Empty = support.Empty;
const Ints = support.Ints;
const Capture = support.IntCapture;
const Event = support.Event;
const double = support.double;

test "stop request is one-shot and checked by schedule; just remains unconditional" {
    var source: ex.StopSource = .{};
    try testing.expect(!source.token().stopRequested());
    try testing.expect(source.requestStop());
    try testing.expect(!source.requestStop());
    const inline_scheduler: ex.InlineScheduler = .{};
    try testing.expectEqual(null, try inline_scheduler.schedule().withStopToken(source.token()).syncWait(.{ .allocator = std.testing.allocator }));
    try testing.expectEqual(1, (try ex.just(.{1}).withStopToken(source.token()).syncWait(.{ .allocator = std.testing.allocator })).?[0]);
    try testing.expectEqual(null, try ex.syncWait(ex.schedule(inline_scheduler), .{ .allocator = std.testing.allocator, .stop_token = source.token() }));
}

test "withStopToken preserves both nested and downstream cancellation" {
    var first: ex.StopSource = .{};
    var second: ex.StopSource = .{};
    var root: ex.StopSource = .{};
    _ = root.requestStop();
    const work = ex.schedule(ex.InlineScheduler{}).withStopToken(first.token()).withStopToken(second.token());
    try testing.expectEqual(null, try ex.syncWait(work, .{ .allocator = std.testing.allocator, .stop_token = root.token() }));
    _ = first.requestStop();
    try testing.expectEqual(null, try work.syncWait(.{ .allocator = std.testing.allocator }));
}

test "whenAll cancels pending siblings without invoking their callbacks" {
    const Never = struct {
        fn call() void {
            @panic("canceled scheduled task ran");
        }
    };
    const work = ex.whenAll(.{
        ex.justError(Empty, error.Broken),
        ex.schedule(ex.InlineScheduler{}).then(ex.Fn(Never.call), .{}),
    });
    try testing.expectError(error.Broken, work.syncWait(.{ .allocator = std.testing.allocator }));
}

test "whenAll requests stop and waits for already running nested siblings" {
    const pool = try ex.ThreadPool.init(testing.allocator, 2);
    defer pool.deinit();
    var entered: Event = .{};
    var finished = std.atomic.Value(bool).init(false);
    const Work = struct {
        entered: *Event,
        finished: *std.atomic.Value(bool),
        pub fn call(self: @This(), env: ex.Env) void {
            self.entered.set();
            while (!env.stop_token.stopRequested()) std.Thread.yield() catch {};
            self.finished.store(true, .release);
        }
    };
    const Fail = struct {
        entered: *Event,
        pub fn call(self: @This()) error{Broken}!void {
            self.entered.wait();
            return error.Broken;
        }
    };
    const nested = ex.whenAll(.{
        ex.readEnv().then(Work, .{ .entered = &entered, .finished = &finished }).startsOn(pool.getScheduler()),
        ex.just(.{}),
    });
    const work = ex.whenAll(.{
        nested,
        ex.schedule(pool.getScheduler()).then(Fail, .{ .entered = &entered }),
    });
    try testing.expectError(error.Broken, work.syncWait(.{ .allocator = std.testing.allocator }));
    try testing.expect(finished.load(.acquire));
}

test "bulk observes cancellation between iterations" {
    var source: ex.StopSource = .{};
    var count: usize = 0;
    const Cancel = struct {
        source: *ex.StopSource,
        count: *usize,
        pub fn call(self: @This(), index: usize) void {
            self.count.* += 1;
            if (index == 2) _ = self.source.requestStop();
        }
    };
    const result = try ex.just(.{}).bulk(100, Cancel, .{ .source = &source, .count = &count }).withStopToken(source.token()).syncWait(.{ .allocator = std.testing.allocator });
    try testing.expectEqual(null, result);
    try testing.expectEqual(3, count);
}

test "cancellation during transfer can replace a stored value with stopped" {
    var source: ex.StopSource = .{};
    _ = source.requestStop();
    const work = ex.just(.{1}).continuesOn(ex.InlineScheduler{}).withStopToken(source.token());
    try testing.expectEqual(null, try work.syncWait(.{ .allocator = std.testing.allocator }));
}
