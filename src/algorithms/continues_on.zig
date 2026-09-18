const std = @import("std");
const c = @import("../execution/protocol.zig");
const schedule = @import("../execution/schedule.zig").schedule;
pub fn ContinuesOn(comptime S: type, comptime Scheduler: type) type {
    const ScheduledSender = @TypeOf(schedule(@as(Scheduler, undefined)));
    return struct {
        sender: S,
        scheduler: Scheduler,
        pub const Values = S.Values;
        const Self = @This();
        pub const Operation = struct {
            sender: S,
            scheduler: Scheduler,
            receiver: c.Receiver(Values),
            child: S.Operation = undefined,
            transfer: ScheduledSender.Operation = undefined,
            result: c.Completion(Values) = undefined,
            started: bool = false,
            const Op = @This();
            const TransferReceiver = struct {
                fn value(ctx: *anyopaque, _: ScheduledSender.Values) void {
                    const op: *Op = @ptrCast(@alignCast(ctx));
                    op.receiver.complete(op.result);
                }
                fn err(ctx: *anyopaque, e: anyerror) void {
                    const op: *Op = @ptrCast(@alignCast(ctx));
                    op.receiver.setError(e);
                }
                fn stopped(ctx: *anyopaque) void {
                    const op: *Op = @ptrCast(@alignCast(ctx));
                    op.receiver.setStopped();
                }
            };
            pub fn start(self: *Op) void {
                std.debug.assert(!self.started);
                self.started = true;
                self.child = self.sender.connect(c.Receiver(Values).init(self));
                self.child.start();
            }
            pub fn getEnv(self: *Op) c.Env {
                return self.receiver.env;
            }
            fn forward(self: *Op, result: c.Completion(Values)) void {
                self.result = result;
                self.transfer = schedule(self.scheduler).connect(.{
                    .context = self,
                    .value_fn = TransferReceiver.value,
                    .error_fn = TransferReceiver.err,
                    .stopped_fn = TransferReceiver.stopped,
                    .env = self.receiver.env,
                });
                self.transfer.start();
            }
            pub fn setValue(self: *Op, values: Values) void {
                self.forward(.{ .value = values });
            }
            pub fn setError(self: *Op, err: anyerror) void {
                self.forward(.{ .err = err });
            }
            pub fn setStopped(self: *Op) void {
                self.forward(.stopped);
            }
        };
        pub fn connect(self: Self, receiver: c.Receiver(Values)) Operation {
            return .{ .sender = self.sender, .scheduler = self.scheduler, .receiver = receiver };
        }
    };
}

pub fn continuesOn(sender: anytype, scheduler: anytype) ContinuesOn(@TypeOf(sender), @TypeOf(scheduler)) {
    return .{ .sender = sender, .scheduler = scheduler };
}
