//! Allocation-free, thread-affine trampoline shared by all sender types.
//! Nested submissions run inline within the outermost scheduler's limits, then
//! enter a FIFO drained before that outermost submit returns. This is not an
//! event loop: an infinite synchronous repeat can monopolize the calling thread.
const std = @import("std");
const Task = @import("../detail/task.zig").Task;
const Scheduled = @import("../detail/scheduled.zig").Scheduled;
const fluent = @import("../execution/sender.zig");

threadlocal var current: ?*State = null;
const State = struct {
    scheduler: TrampolineScheduler,
    origin: usize,
    depth: usize = 1,
    head: ?*Task = null,
    tail: ?*Task = null,

    fn enqueue(self: *State, task: *Task) void {
        task.next = null;
        if (self.tail) |tail| tail.next = task else self.head = task;
        self.tail = task;
    }
    fn drain(self: *State) void {
        while (self.head) |task| {
            self.head = task.next;
            if (self.head == null) self.tail = null;
            task.next = null;
            // Detach before execution: a callback can resubmit or destroy task.
            self.depth = 1;
            self.origin = @intFromPtr(&task);
            task.run(task);
        }
    }
};

pub const TrampolineScheduler = struct {
    max_depth: usize = 16,
    max_stack_bytes: usize = 4096,

    /// Counts submit() calls in safety-checked builds so tests can assert that a
    /// synchronous chain does not pay a hop per round. Always zero in release.
    var submission_count: if (std.debug.runtime_safety) usize else void =
        if (std.debug.runtime_safety) 0 else {};

    pub fn submissions() usize {
        return if (std.debug.runtime_safety) submission_count else 0;
    }

    pub fn schedule(self: TrampolineScheduler) fluent.Sender(Scheduled(TrampolineScheduler)) {
        return fluent.asSender(Scheduled(TrampolineScheduler){ .scheduler = self });
    }
    pub fn submit(self: TrampolineScheduler, task: *Task) error{}!void {
        if (std.debug.runtime_safety) submission_count += 1;
        if (current) |state| {
            const address = @intFromPtr(&task);
            const distance = @max(address, state.origin) - @min(address, state.origin);
            if (state.depth < state.scheduler.max_depth and distance < state.scheduler.max_stack_bytes) {
                state.depth += 1;
                defer state.depth -= 1;
                task.run(task);
            } else state.enqueue(task);
        } else {
            var state: State = .{ .scheduler = self, .origin = @intFromPtr(&task) };
            current = &state;
            defer current = null;
            task.run(task);
            state.drain();
        }
    }
};
