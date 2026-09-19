const ImmediateKind = @import("immediate.zig").ImmediateKind;
pub fn justStopped(comptime Values: type) ImmediateKind(Values, .stopped) {
    return .{ .result = .stopped };
}
