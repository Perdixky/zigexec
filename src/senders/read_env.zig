const std = @import("std");
const c = @import("../execution/protocol.zig");
pub const ReadEnv = struct {
    pub const can_error = false;
    pub const Values = @Tuple(&.{c.Env});
    pub fn Operation(comptime R: type) type {
        return struct {
            receiver: c.TypedReceiver(Values, R),
            output: Values = undefined,
            started: bool = false,
            pub fn start(self: *@This()) void {
                std.debug.assert(!self.started);
                self.started = true;
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
