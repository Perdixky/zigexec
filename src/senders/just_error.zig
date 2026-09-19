const ImmediateKind = @import("immediate.zig").ImmediateKind;
/// Explicit success tuple type keeps recovery and composition statically typed.
pub fn justError(comptime Values: type, err: anyerror) ImmediateKind(Values, .err) {
    return .{ .result = .{ .err = err } };
}
