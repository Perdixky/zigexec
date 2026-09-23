const std = @import("std");
const StartGuard = @import("../detail/start_guard.zig").StartGuard;
const protocol = @import("../execution/protocol.zig");

const canError = @import("../detail/completion_traits.zig").canError;
const schedule = @import("../execution/schedule.zig").schedule;

pub fn StartsOn(comptime Scheduler: type, comptime S: type) type {
    const Scheduled = @TypeOf(schedule(@as(Scheduler, undefined)));
    return struct {
        scheduler: Scheduler,
        sender: S,
        pub const Values = S.Values;
        pub const can_error = canError(S) or canError(Scheduled);
        const Self = @This();
        pub fn Operation(comptime R: type) type {
            return struct {
                receiver: protocol.TypedReceiver(Values, R),
                scheduled: protocol.OperationOf(Scheduled, *Op) = undefined,
                child: protocol.OperationOf(S, protocol.TypedReceiver(Values, R)) = undefined,
                started: StartGuard = .{},
                const Op = @This();
                pub fn cleanup(self: *Op, continuation: anytype) void {
                    protocol.cleanupOperations(.{ &self.child, &self.scheduled }, continuation);
                }
                pub fn start(self: *Op) void {
                    self.started.begin();
                    self.scheduled.start();
                }
                pub fn getEnv(self: *Op) protocol.EnvOf(R) {
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
        pub fn connectInto(self: Self, out: anytype, r: anytype) void {
            out.* = .{ .receiver = .init(r) };
            protocol.connectChild(&out.scheduled, schedule(self.scheduler), out);
            protocol.connectChild(&out.child, self.sender, out.receiver);
        }
    };
}
pub fn startsOn(scheduler: anytype, sender: anytype) StartsOn(@TypeOf(scheduler), @TypeOf(sender)) {
    return .{ .scheduler = scheduler, .sender = sender };
}
