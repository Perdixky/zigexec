const std = @import("std");
const StartGuard = @import("../detail/start_guard.zig").StartGuard;
const c = @import("../execution/protocol.zig");
pub fn Immediate(comptime V: type) type {
    return ImmediateKind(V, null);
}
pub fn ImmediateKind(comptime V: type, comptime channel: ?enum { value, err, stopped }) type {
    return struct {
        result: c.Completion(V),
        pub const Values = V;
        pub const can_error = channel == null or channel == .err;
        const Self = @This();
        pub fn Operation(comptime R: type) type {
            return struct {
                receiver: c.TypedReceiver(V, R),
                result: c.Completion(V),
                started: StartGuard = .{},
                pub fn start(self: *@This()) void {
                    self.started.begin();
                    self.receiver.complete(&self.result);
                }
            };
        }
        pub fn connectInto(self: Self, out: anytype, receiver: anytype) void {
            out.* = .{ .receiver = .init(receiver), .result = self.result };
        }
    };
}
