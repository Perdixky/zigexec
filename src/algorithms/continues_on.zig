const traits = @import("../detail/completion_traits.zig");
const std = @import("std");
const c = @import("../execution/protocol.zig");
const schedule = @import("../execution/schedule.zig").schedule;
pub fn ContinuesOn(comptime S: type, comptime Scheduler: type) type {
    const ScheduledSender = @TypeOf(schedule(@as(Scheduler, undefined)));
    return struct {
        sender: S,
        scheduler: Scheduler,
        pub const Values = S.Values;
        pub const can_error = traits.canError(S) or traits.canError(ScheduledSender);
        const Self = @This();
        pub fn Operation(comptime R: type) type {
            return struct {
                receiver: c.TypedReceiver(Values, R),
                child: c.OperationOf(S, *Op) = undefined,
                transfer: c.OperationOf(ScheduledSender, TransferReceiver) = undefined,
                result: c.CompletionRef(Values) = undefined,
                started: bool = false,
                const Op = @This();
                const TransferReceiver = struct {
                    op: *Op,
                    pub fn getEnv(self: @This()) c.EnvOf(R) {
                        return self.op.receiver.getEnv();
                    }
                    pub fn setValue(self: @This(), _: *const ScheduledSender.Values) void {
                        self.op.receiver.completeRef(self.op.result);
                    }
                    pub fn setError(self: @This(), e: anyerror) void {
                        self.op.receiver.setError(e);
                    }
                    pub fn setStopped(self: @This()) void {
                        self.op.receiver.setStopped();
                    }
                };
                pub fn start(self: *Op) void {
                    std.debug.assert(!self.started);
                    self.started = true;
                    self.child.start();
                }
                pub fn getEnv(self: *Op) c.EnvOf(R) {
                    return self.receiver.getEnv();
                }
                fn forward(self: *Op, result: c.CompletionRef(Values)) void {
                    self.result = result;
                    self.transfer.start();
                }
                pub fn setValue(self: *Op, values: *const Values) void {
                    self.forward(.{ .value = values });
                }
                pub fn setError(self: *Op, err: anyerror) void {
                    self.forward(.{ .err = err });
                }
                pub fn setStopped(self: *Op) void {
                    self.forward(.stopped);
                }
            };
        }
        pub fn connectInto(self: Self, out: anytype, receiver: anytype) void {
            out.* = .{ .receiver = .init(receiver) };
            c.connectChild(&out.child, self.sender, out);
            c.connectChild(&out.transfer, schedule(self.scheduler), Operation(@TypeOf(receiver)).TransferReceiver{ .op = out });
        }
    };
}

pub fn continuesOn(sender: anytype, scheduler: anytype) ContinuesOn(@TypeOf(sender), @TypeOf(scheduler)) {
    return .{ .sender = sender, .scheduler = scheduler };
}
