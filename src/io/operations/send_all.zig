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
        pub fn Operation(comptime R: type) type {
            return struct {
                sender: Self,
                receiver: ex.TypedReceiver(Values, R),
                offset: usize = 0,
                output: Values = .{0},
                child: ex.meta.OperationOf(Loop, *Op) = undefined,
                started: bool = false,
                const Op = @This();
                pub fn cleanup(self: *Op, continuation: anytype) void {
                    ex.cleanupOperation(&self.child, continuation);
                }
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
                const Loop = ex.Just(.{}).LetValue(Next).Then(Advance).RepeatUntil();
                pub fn start(self: *Op) void {
                    std.debug.assert(!self.started);
                    self.started = true;
                    if (self.receiver.getEnv().stop_token.stopRequested()) return self.receiver.setStopped();
                    if (self.sender.buffer.len == 0) return self.receiver.setValue(&self.output);
                    self.child.start();
                }
                pub fn getEnv(self: *Op) ex.EnvOf(R) {
                    return self.receiver.getEnv();
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
        }
        pub fn connectInto(self: Self, out: anytype, receiver: anytype) void {
            out.* = .{ .sender = self, .receiver = .init(receiver) };
            const Op = Operation(@TypeOf(receiver));
            const loop = ex.just(.{}).letValue(Op.Next, .{out}).then(Op.Advance, .{out}).repeatUntil();
            @import("../../execution/protocol.zig").connectChild(&out.child, loop, out);
        }
    };
}

pub fn sendAll(context: anytype, fd: i32, buffer: []const u8, flags: u32) ex.Sender(SendAll(@TypeOf(context))) {
    return ex.asSender(SendAll(@TypeOf(context)){ .context = context, .fd = fd, .buffer = buffer, .flags = flags });
}
