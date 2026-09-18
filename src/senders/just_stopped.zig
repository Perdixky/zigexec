const Immediate = @import("immediate.zig").Immediate;
pub fn justStopped(comptime Values: type) Immediate(Values) {
    return .{ .result = .stopped };
}
