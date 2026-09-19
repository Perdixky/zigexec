const traits = @import("completion_traits.zig");
const std = @import("std");
const c = @import("../execution/protocol.zig");
const Task = @import("task.zig").Task;
pub fn Scheduled(comptime Scheduler: type) type {
    return struct {
        scheduler: Scheduler,
        pub const Values = @Tuple(&.{});
        pub const can_error = traits.fallible(@typeInfo(@TypeOf(Scheduler.submit)).@"fn".return_type.?);
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
                const scope = self.receiver.env.scope;
                c.Scope.acquire(scope);
                self.scheduler.submit(&self.task) catch |err| {
                    self.receiver.setError(err);
                    c.Scope.release(scope);
                };
            }
            fn execute(task: *Task) void {
                const self: *Op = @fieldParentPtr("task", task);
                const scope = self.receiver.env.scope;
                defer c.Scope.release(scope);
                if (self.receiver.env.stop_token.stopRequested())
                    self.receiver.setStopped()
                else
                    self.receiver.setValue(&.{});
            }
        };
        pub fn connect(self: Self, receiver: c.Receiver(Values)) Operation {
            return .{ .scheduler = self.scheduler, .receiver = receiver };
        }
    };
}
