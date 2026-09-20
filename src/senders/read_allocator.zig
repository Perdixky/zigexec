const std = @import("std");
const c = @import("../execution/protocol.zig");

/// Query lazily, after connection to the final receiver's execution environment.
pub const ReadAllocator = struct {
    pub const Values = @Tuple(&.{std.mem.Allocator});
    pub fn Operation(comptime R: type) type {
        return struct {
            receiver: c.TypedReceiver(Values, R),
            output: Values = undefined,
            started: bool = false,
            pub fn start(self: *@This()) void {
                std.debug.assert(!self.started);
                self.started = true;
                const allocator = self.receiver.getEnv().getAllocator() catch |err| return self.receiver.setError(err);
                self.output = .{allocator};
                self.receiver.setValue(&self.output);
            }
        };
    }
    pub fn connectInto(_: @This(), out: anytype, receiver: anytype) void {
        out.* = .{ .receiver = .init(receiver) };
    }
};
