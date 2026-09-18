const std = @import("std");
const c = @import("../execution/protocol.zig");
const fluent = @import("../execution/sender.zig");
const Task = @import("../detail/task.zig").Task;
const Scheduled = @import("../detail/scheduled.zig").Scheduled;
pub const InlineScheduler = struct {
    pub fn schedule(self: InlineScheduler) fluent.Sender(Scheduled(InlineScheduler)) {
        return fluent.asSender(Scheduled(InlineScheduler){ .scheduler = self });
    }
    pub fn submit(_: InlineScheduler, task: *Task) error{}!void {
        task.run(task);
    }
};
