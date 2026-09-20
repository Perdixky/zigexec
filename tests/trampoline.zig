const std = @import("std");
const ex = @import("zigexec");
const t = std.testing;

test "trampoline bounds reentrant heterogeneous work and preserves queued FIFO" {
    const State = struct {
        a: ex.ScheduleTask = .{ .run = runA },
        b: ex.ScheduleTask = .{ .run = runB },
        visits: usize = 0,
        depth: usize = 0,
        max_depth: usize = 0,
        next_a: bool = true,
        fn runA(task: *ex.ScheduleTask) void {
            const self: *@This() = @fieldParentPtr("a", task);
            std.debug.assert(self.next_a);
            self.next_a = false;
            self.step(&self.b);
        }
        fn runB(task: *ex.ScheduleTask) void {
            const self: *@This() = @fieldParentPtr("b", task);
            std.debug.assert(!self.next_a);
            self.next_a = true;
            self.step(&self.a);
        }
        fn step(self: *@This(), next: *ex.ScheduleTask) void {
            self.depth += 1;
            defer self.depth -= 1;
            self.max_depth = @max(self.depth, self.max_depth);
            self.visits += 1;
            if (self.visits < 100_000) (ex.TrampolineScheduler{}).submit(next) catch unreachable;
        }
        fn run(self: *@This()) void {
            (ex.TrampolineScheduler{ .max_depth = 1 }).submit(&self.a) catch unreachable;
        }
    };
    var states: [4]State = @splat(.{});
    var threads: [4]std.Thread = undefined;
    for (&states, &threads) |*state, *thread| thread.* = try std.Thread.spawn(.{}, State.run, .{state});
    for (threads) |thread| thread.join();
    for (states) |state| {
        try t.expectEqual(100_000, state.visits);
        try t.expectEqual(1, state.max_depth);
    }
}

test "trampoline detaches queued nodes before callbacks destroy them" {
    const Node = struct {
        task: ex.ScheduleTask = .{ .run = run },
        result: *usize,
        value: usize,
        fn run(task: *ex.ScheduleTask) void {
            const self: *@This() = @fieldParentPtr("task", task);
            self.result.* = self.result.* * 10 + self.value;
            t.allocator.destroy(self);
        }
    };
    const Root = struct {
        task: ex.ScheduleTask = .{ .run = run },
        first: *Node,
        second: *Node,
        fn run(task: *ex.ScheduleTask) void {
            const self: *@This() = @fieldParentPtr("task", task);
            (ex.TrampolineScheduler{}).submit(&self.first.task) catch unreachable;
            (ex.TrampolineScheduler{}).submit(&self.second.task) catch unreachable;
            std.debug.assert(self.first.result.* == 0);
        }
    };
    var result: usize = 0;
    const first = try t.allocator.create(Node);
    first.* = .{ .result = &result, .value = 1 };
    const second = try t.allocator.create(Node);
    second.* = .{ .result = &result, .value = 2 };
    var root: Root = .{ .first = first, .second = second };
    // A zero stack budget also forces nested schedulers into the outer FIFO.
    try (ex.TrampolineScheduler{ .max_stack_bytes = 0 }).submit(&root.task);
    try t.expectEqual(12, result);
}

test "trampoline schedule checks cancellation when executed" {
    var source: ex.StopSource = .{};
    defer source.deinit();
    _ = source.requestStop();
    try t.expectEqual(null, try (ex.TrampolineScheduler{}).schedule().withStopToken(source.token()).syncWait(.{}));
    try t.expect((try (ex.TrampolineScheduler{}).schedule().syncWait(.{})) != null);
}
