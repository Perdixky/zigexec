const std = @import("std");
const ex = @import("../../root.zig");
const io = @import("../root.zig");

/// Send the complete slice, retrying short sends. Storage remains borrowed until
/// completion. An error/stop can occur after a prefix has already been sent.
pub fn SendAll(comptime Context: type) type {
    return struct {
        context: Context,
        fd: i32,
        buffer: []const u8,
        flags: u32,
        pub const Values = ex.Values(.{usize});
        const Self = @This();
        pub const Operation = struct {
            sender: Self,
            receiver: ex.Receiver(Values),
            offset: usize = 0,
            output: Values = .{0},
            child: Loop.Operation = undefined,
            started: bool = false,
            const Op = @This();
            const Next = struct {
                operation: *Op,
                pub fn call(self: @This()) io.Send(Context) {
                    const op = self.operation;
                    return io.send(op.sender.context, op.sender.fd, op.sender.buffer[op.offset..], op.sender.flags);
                }
            };
            const Advance = struct {
                operation: *Op,
                pub fn call(self: @This(), count: usize) error{WriteZero}!bool {
                    const op = self.operation;
                    if (count == 0) return error.WriteZero;
                    std.debug.assert(count <= op.sender.buffer.len - op.offset);
                    op.offset += count;
                    return op.offset == op.sender.buffer.len;
                }
            };
            const Loop = ex.Just(.{}).LetValue(Next).Then(Advance).RepeatEffectUntil();
            pub fn start(self: *Op) void {
                std.debug.assert(!self.started);
                self.started = true;
                if (self.receiver.env.stop_token.stopRequested()) return self.receiver.setStopped();
                if (self.sender.buffer.len == 0) return self.receiver.setValue(&self.output);
                const loop = ex.just(.{}).letValue(Next, .{self}).then(Advance, .{self}).repeatEffectUntil();
                self.child = loop.connect(ex.Receiver(ex.Values(.{})).init(self));
                self.child.start();
            }
            pub fn getEnv(self: *Op) ex.Env {
                return self.receiver.env;
            }
            pub fn setValue(self: *Op, _: *const ex.Values(.{})) void {
                self.output = .{self.offset};
                self.receiver.setValue(&self.output);
            }
            pub fn setError(self: *Op, err: anyerror) void {
                self.receiver.setError(err);
            }
            pub fn setStopped(self: *Op) void {
                self.receiver.setStopped();
            }
        };
        pub fn connect(self: Self, receiver: ex.Receiver(Values)) Operation {
            return .{ .sender = self, .receiver = receiver };
        }
    };
}

pub fn sendAll(context: anytype, fd: i32, buffer: []const u8, flags: u32) ex.Sender(SendAll(@TypeOf(context))) {
    return ex.asSender(SendAll(@TypeOf(context)){ .context = context, .fd = fd, .buffer = buffer, .flags = flags });
}
