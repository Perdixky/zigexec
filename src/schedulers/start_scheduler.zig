//! Borrowed, allocation-free scheduler handle for the runtime Env boundary.
//! The pointed-to scheduler supports submit(*ScheduleTask) !void and must remain
//! stable until scheduled work finishes. Ordinary sender graphs remain generic.
const Task = @import("../detail/task.zig").Task;
const fluent = @import("../execution/sender.zig");
const Scheduled = @import("../detail/scheduled.zig").Scheduled;
const Self = @This();
context: *const anyopaque,
submit_fn: *const fn (*const anyopaque, *Task) anyerror!void,

pub fn init(pointer: anytype) Self {
    const P = @TypeOf(pointer);
    if (@typeInfo(P) != .pointer or @typeInfo(P).pointer.size != .one)
        @compileError("zigexec.StartScheduler.init: pass a pointer to a stable scheduler");
    const Bridge = struct {
        fn submit(ctx: *const anyopaque, task: *Task) anyerror!void {
            const scheduler: P = @ptrCast(@alignCast(@constCast(ctx)));
            return scheduler.submit(task);
        }
    };
    return .{ .context = pointer, .submit_fn = Bridge.submit };
}
pub fn submit(self: Self, task: *Task) anyerror!void {
    return self.submit_fn(self.context, task);
}
pub fn schedule(self: Self) fluent.Sender(Scheduled(Self)) {
    return fluent.asSender(Scheduled(Self){ .scheduler = self });
}
