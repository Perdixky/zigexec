const std = @import("std");
const c = @import("../execution/protocol.zig");
pub fn Bulk(comptime S: type, comptime F: type) type {
    const Args = @TypeOf(.{@as(usize, 0)} ++ @as(S.Values, undefined));
    if (c.Payload(c.CheckedResult(F, Args, "bulk")) != void) @compileError("bulk callback must return void or !void");
    return struct {
        sender: S,
        count: usize,
        callback: F,
        pub const Values = S.Values;
        const Self = @This();
        pub const Operation = struct {
            sender: S,
            count: usize,
            callback: F,
            receiver: c.Receiver(Values),
            child: S.Operation = undefined,
            started: bool = false,
            const Op = @This();
            pub fn start(self: *Op) void {
                std.debug.assert(!self.started);
                self.started = true;
                self.child = self.sender.connect(c.Receiver(Values).init(self));
                self.child.start();
            }
            pub fn getEnv(self: *Op) c.Env {
                return self.receiver.env;
            }
            pub fn setValue(self: *Op, values: *const Values) void {
                for (0..self.count) |i| {
                    if (self.receiver.env.stop_token.stopRequested()) return self.receiver.setStopped();
                    const result = c.invokeStored(&self.callback, .{i} ++ values.*);
                    if (comptime @typeInfo(@TypeOf(result)) == .error_union) {
                        result catch |err| return self.receiver.setError(err);
                    }
                }
                self.receiver.setValue(values);
            }
            pub fn setError(self: *Op, err: anyerror) void {
                self.receiver.setError(err);
            }
            pub fn setStopped(self: *Op) void {
                self.receiver.setStopped();
            }
        };
        pub fn connect(self: Self, receiver: c.Receiver(Values)) Operation {
            return .{ .sender = self.sender, .count = self.count, .callback = self.callback, .receiver = receiver };
        }
    };
}

/// Sequential bulk on the predecessor's completion thread. Use whenAll and
/// startsOn for parallel branches; bulk itself makes no parallelism guarantee.
pub fn bulk(sender: anytype, count: usize, callback: anytype) Bulk(@TypeOf(sender), c.Stored(@TypeOf(callback))) {
    return .{ .sender = sender, .count = count, .callback = callback };
}
