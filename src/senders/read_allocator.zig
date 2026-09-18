const std = @import("std");
const c = @import("../execution/protocol.zig");

/// Query lazily, after connection to the final receiver's execution environment.
pub const ReadAllocator = struct {
    pub const Values = @Tuple(&.{std.mem.Allocator});
    pub const Operation = struct {
        receiver: c.Receiver(Values),
        started: bool = false,
        pub fn start(self: *@This()) void {
            std.debug.assert(!self.started);
            self.started = true;
            self.receiver.setValue(.{self.receiver.getEnv().getAllocator()});
        }
    };
    pub fn connect(_: @This(), receiver: c.Receiver(Values)) Operation {
        return .{ .receiver = receiver };
    }
};
