const std = @import("std");
const c = @import("../execution/protocol.zig");
pub fn Immediate(comptime V: type) type {
    return struct {
        result: c.Completion(V),
        pub const Values = V;
        const Self = @This();
        pub const Operation = struct {
            receiver: c.Receiver(V),
            result: c.Completion(V),
            started: bool = false,
            pub fn start(self: *@This()) void {
                std.debug.assert(!self.started);
                self.started = true;
                self.receiver.complete(self.result);
            }
        };
        pub fn connect(self: Self, receiver: c.Receiver(V)) Operation {
            return .{ .receiver = receiver, .result = self.result };
        }
    };
}
