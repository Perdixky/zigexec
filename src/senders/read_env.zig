const std = @import("std");
const c = @import("../execution/protocol.zig");
pub const ReadEnv = struct {
    pub const Values = @Tuple(&.{c.Env});
    pub const Operation = struct {
        receiver: c.Receiver(Values),
        started: bool = false,
        pub fn start(self: *@This()) void {
            std.debug.assert(!self.started);
            self.started = true;
            self.receiver.setValue(.{self.receiver.env});
        }
    };
    pub fn connect(_: ReadEnv, receiver: c.Receiver(Values)) Operation {
        return .{ .receiver = receiver };
    }
};

pub fn readEnv() ReadEnv {
    return .{};
}
