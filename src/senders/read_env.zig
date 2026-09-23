const std = @import("std");
const StartGuard = @import("../detail/start_guard.zig").StartGuard;
const c = @import("../execution/protocol.zig");
pub const ReadEnv = struct {
    pub const can_error = false;
    pub const Values = @Tuple(&.{c.Env});
    pub fn Operation(comptime R: type) type {
        return struct {
            receiver: c.TypedReceiver(Values, R),
            output: Values = undefined,
            started: StartGuard = .{},
            pub fn start(self: *@This()) void {
                self.started.begin();
                self.output = .{self.receiver.getEnv().toDynamic()};
                self.receiver.setValue(&self.output);
            }
        };
    }
    pub fn connectInto(_: ReadEnv, out: anytype, receiver: anytype) void {
        out.* = .{ .receiver = .init(receiver) };
    }
};

pub fn readEnv() ReadEnv {
    return .{};
}
