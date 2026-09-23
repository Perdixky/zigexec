const traits = @import("../detail/completion_traits.zig");
const StartGuard = @import("../detail/start_guard.zig").StartGuard;
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
        pub const can_error = traits.canError(S) or traits.fallible(c.CheckedResult(F, Args, "bulk"));
        const Self = @This();
        pub fn Operation(comptime R: type) type {
            return struct {
                count: usize,
                callback: F,
                receiver: c.TypedReceiver(Values, R),
                child: c.OperationOf(S, *Op) = undefined,
                started: StartGuard = .{},
                const Op = @This();
                pub fn cleanup(self: *Op, continuation: anytype) void {
                    c.cleanupOperation(&self.child, continuation);
                }
                pub fn start(self: *Op) void {
                    self.started.begin();
                    self.child.start();
                }
                pub fn getEnv(self: *Op) c.EnvOf(R) {
                    return self.receiver.getEnv();
                }
                pub fn setValue(self: *Op, values: *const Values) void {
                    for (0..self.count) |i| {
                        if (self.receiver.getEnv().stop_token.stopRequested()) return self.receiver.setStopped();
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
        }
        pub fn connectInto(self: Self, out: anytype, receiver: anytype) void {
            out.* = .{ .count = self.count, .callback = self.callback, .receiver = .init(receiver) };
            c.connectChild(&out.child, self.sender, out);
        }
    };
}

/// Sequential bulk on the predecessor's completion thread. Use whenAll and
/// startsOn for parallel branches; bulk itself makes no parallelism guarantee.
pub fn bulk(sender: anytype, count: usize, callback: anytype) Bulk(@TypeOf(sender), c.Stored(@TypeOf(callback))) {
    return .{ .sender = sender, .count = count, .callback = callback };
}
