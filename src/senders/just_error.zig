const Immediate = @import("immediate.zig").Immediate;
/// Explicit success tuple type keeps recovery and composition statically typed.
pub fn justError(comptime Values: type, err: anyerror) Immediate(Values) {
    return .{ .result = .{ .err = err } };
}
