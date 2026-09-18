const std = @import("std");
const c = @import("../execution/protocol.zig");
const Task = @import("task.zig").Task;
pub fn Scheduled(comptime Scheduler: type) type {
    return struct {
        scheduler: Scheduler,
        pub const Values = @Tuple(&.{});
        const Self = @This();
        pub const Operation = struct {
            scheduler: Scheduler,
            receiver: c.Receiver(Values),
            task: Task = .{ .run = execute },
            started: bool = false,
            const Op = @This();
            pub fn start(self: *Op) void {
                std.debug.assert(!self.started);
                self.started = true;
                self.scheduler.submit(&self.task) catch |err| self.receiver.setError(err);
            }
            fn execute(task: *Task) void {
                const self: *Op = @fieldParentPtr("task", task);
                if (self.receiver.env.stop_token.stopRequested())
                    self.receiver.setStopped()
                else
                    self.receiver.setValue(.{});
            }
        };
        pub fn connect(self: Self, receiver: c.Receiver(Values)) Operation {
            return .{ .scheduler = self.scheduler, .receiver = receiver };
        }
    };
}
