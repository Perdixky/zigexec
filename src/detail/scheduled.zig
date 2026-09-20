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
        pub fn Operation(comptime R: type) type {
            return struct {
                scheduler: Scheduler,
                receiver: c.TypedReceiver(Values, R),
                task: Task = .{ .run = execute },
                started: bool = false,
                const Op = @This();
                pub fn start(self: *Op) void {
                    std.debug.assert(!self.started);
                    self.started = true;
                    self.scheduler.submit(&self.task) catch |err| {
                        self.receiver.setError(err);
                    };
                }
                fn execute(task: *Task) void {
                    const self: *Op = @fieldParentPtr("task", task);
                    if (self.receiver.getEnv().stop_token.stopRequested())
                        self.receiver.setStopped()
                    else
                        self.receiver.setValue(&.{});
                }
            };
        }
        pub fn connectInto(self: Self, out: anytype, receiver: anytype) void {
            out.* = .{ .scheduler = self.scheduler, .receiver = .init(receiver) };
        }
    };
}
