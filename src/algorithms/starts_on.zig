const std = @import("std");
const c = @import("../execution/protocol.zig");
const traits = @import("../detail/completion_traits.zig");
const schedule = @import("../execution/schedule.zig").schedule;

pub fn StartsOn(comptime Scheduler: type, comptime S: type) type {
    const Scheduled = @TypeOf(schedule(@as(Scheduler, undefined)));
    return struct {
        scheduler: Scheduler,
        sender: S,
        pub const Values = S.Values;
        pub const can_error = traits.canError(S) or traits.canError(Scheduled);
        const Self = @This();
        pub fn Operation(comptime R: type) type {
            return struct {
                receiver: c.TypedReceiver(Values, R),
                scheduled: c.OperationOf(Scheduled, *Op) = undefined,
                child: c.OperationOf(S, c.TypedReceiver(Values, R)) = undefined,
                started: bool = false,
                const Op = @This();
                pub fn start(self: *Op) void {
                    std.debug.assert(!self.started);
                    self.started = true;
                    self.scheduled.start();
                }
                pub fn getEnv(self: *Op) c.EnvOf(R) {
                    return self.receiver.getEnv();
                }
                pub fn setValue(self: *Op, _: *const Scheduled.Values) void {
                    self.child.start();
                }
                pub fn setError(self: *Op, err: anyerror) void {
                    self.receiver.setError(err);
                }
                pub fn setStopped(self: *Op) void {
                    self.receiver.setStopped();
                }
            };
        }
        pub fn connectInto(self: Self, out: anytype, receiver: anytype) void {
            out.* = .{ .receiver = .init(receiver) };
            c.connectChild(&out.scheduled, schedule(self.scheduler), out);
            c.connectChild(&out.child, self.sender, out.receiver);
        }
    };
}
pub fn startsOn(scheduler: anytype, sender: anytype) StartsOn(@TypeOf(scheduler), @TypeOf(sender)) {
    return .{ .scheduler = scheduler, .sender = sender };
}
