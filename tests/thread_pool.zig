//! Work-stealing pool invariants: every accepted task runs exactly once, no
//! wakeup is lost (a lost wakeup hangs these tests), and close drains work.
const std = @import("std");
const ex = @import("zigexec");
const t = std.testing;

const Counter = struct {
    task: ex.ScheduleTask = .{ .run = run },
    pool: *ex.ThreadPool,
    runs: std.atomic.Value(u32) = .init(0),
    children: []Counter = &.{},
    total: *std.atomic.Value(usize),
    fn run(task: *ex.ScheduleTask) void {
        const self: *Counter = @fieldParentPtr("task", task);
        std.debug.assert(self.runs.fetchAdd(1, .monotonic) == 0);
        _ = self.total.fetchAdd(1, .monotonic);
        for (self.children) |*child| self.pool.getScheduler().submit(&child.task) catch unreachable;
    }
};

fn waitFor(total: *std.atomic.Value(usize), expected: usize) void {
    while (total.load(.acquire) != expected) std.Thread.yield() catch {};
}

test "thread pool runs every externally submitted task exactly once" {
    for ([_]usize{ 1, 2, 4, 8 }) |workers| {
        const pool = try ex.ThreadPool.init(t.allocator, workers);
        defer pool.deinit();
        var total = std.atomic.Value(usize).init(0);
        const tasks = try t.allocator.alloc(Counter, 20_000);
        defer t.allocator.free(tasks);
        for (tasks) |*task| task.* = .{ .pool = pool, .total = &total };
        const Submitter = struct {
            fn run(p: *ex.ThreadPool, slice: []Counter) void {
                for (slice) |*task| p.getScheduler().submit(&task.task) catch unreachable;
            }
        };
        var threads: [4]std.Thread = undefined;
        const per = tasks.len / threads.len;
        for (&threads, 0..) |*thread, i| thread.* = try std.Thread.spawn(.{}, Submitter.run, .{ pool, tasks[i * per ..][0..per] });
        for (threads) |thread| thread.join();
        waitFor(&total, tasks.len);
        for (tasks) |*task| try t.expectEqual(1, task.runs.load(.monotonic));
    }
}

test "thread pool worker submissions overflow and get stolen without loss" {
    for ([_]usize{ 1, 3, 6 }) |workers| {
        const pool = try ex.ThreadPool.init(t.allocator, workers);
        defer pool.deinit();
        var total = std.atomic.Value(usize).init(0);
        // One root fans out 1000 children from a worker: more than a ring holds,
        // so some go to the injection queue while idle workers steal the rest.
        const children = try t.allocator.alloc(Counter, 1000);
        defer t.allocator.free(children);
        for (children) |*child| child.* = .{ .pool = pool, .total = &total };
        for (0..50) |_| {
            total.store(0, .monotonic);
            for (children) |*child| child.runs.store(0, .monotonic);
            var root: Counter = .{ .pool = pool, .total = &total, .children = children };
            try pool.getScheduler().submit(&root.task);
            waitFor(&total, children.len + 1);
            for (children) |*child| try t.expectEqual(1, child.runs.load(.monotonic));
        }
    }
}

test "thread pool idle-to-busy transitions never lose a wakeup" {
    // Sequential round trips force workers to park between almost every task,
    // which is where a missed notification would strand work.
    const pool = try ex.ThreadPool.init(t.allocator, 4);
    defer pool.deinit();
    for (0..20_000) |i| {
        const result = try ex.just(.{@as(i64, @intCast(i))}).startsOn(pool.getScheduler()).syncWait(.{});
        try t.expectEqual(@as(i64, @intCast(i)), result.?[0]);
    }
}

test "thread pool deinit drains accepted work and rejects later submissions" {
    for (0..200) |_| {
        const pool = try ex.ThreadPool.init(t.allocator, 3);
        var total = std.atomic.Value(usize).init(0);
        var tasks: [64]Counter = undefined;
        for (&tasks) |*task| {
            task.* = .{ .pool = pool, .total = &total };
            try pool.getScheduler().submit(&task.task);
        }
        pool.deinit(); // Must run all 64 before joining.
        try t.expectEqual(tasks.len, total.load(.monotonic));
    }
    const pool = try ex.ThreadPool.init(t.allocator, 1);
    const closed = pool.getScheduler();
    pool.close();
    var total = std.atomic.Value(usize).init(0);
    var task: Counter = .{ .pool = pool, .total = &total };
    try t.expectError(error.SchedulerStopped, closed.submit(&task.task));
    pool.deinit();
}

test "thread pool runs every task accepted while racing close" {
    const Submitter = struct {
        fn run(pool: *ex.ThreadPool, tasks: []Counter, accepted: *usize) void {
            for (tasks) |*task| {
                pool.getScheduler().submit(&task.task) catch return;
                accepted.* += 1;
            }
        }
    };
    const tasks = try t.allocator.alloc(Counter, 4 * 2_000);
    defer t.allocator.free(tasks);
    for (0..100) |_| {
        const pool = try ex.ThreadPool.init(t.allocator, 2);
        var total = std.atomic.Value(usize).init(0);
        for (tasks) |*task| task.* = .{ .pool = pool, .total = &total };
        var accepted: [4]usize = @splat(0);
        var threads: [4]std.Thread = undefined;
        for (&threads, 0..) |*thread, i| thread.* = try std.Thread.spawn(.{}, Submitter.run, .{ pool, tasks[i * 2_000 ..][0..2_000], &accepted[i] });
        pool.close(); // Races the submitters; some submissions are rejected.
        for (threads) |thread| thread.join();
        pool.deinit();
        var sum: usize = 0;
        for (accepted) |n| sum += n;
        try t.expectEqual(sum, total.load(.monotonic));
    }
}
