const std = @import("std");
const c = @import("../execution/protocol.zig");
const fluent = @import("../execution/sender.zig");
const Task = @import("../detail/task.zig").Task;
const Queue = @import("../detail/queue.zig").Queue;
const Scheduled = @import("../detail/scheduled.zig").Scheduled;
pub const QueueScheduler = struct {
    queue: *Queue,
    pub fn schedule(self: QueueScheduler) fluent.Sender(Scheduled(QueueScheduler)) {
        return fluent.asSender(Scheduled(QueueScheduler){ .scheduler = self });
    }
    pub fn submit(self: QueueScheduler, task: *Task) error{SchedulerStopped}!void {
        return self.queue.submit(task);
    }
};
