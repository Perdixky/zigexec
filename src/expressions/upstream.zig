const ex = @import("../root.zig");
const Expression = @import("chain.zig").Expression;

/// Forward the nearest letValue scope's completion values. Slices and pointers
/// copy their descriptors; ownership of the referenced storage stays explicit.
pub fn upstream() Expression(Input) {
    return .{ .inner = .{} };
}

const Input = struct {
    pub fn Bound(comptime Values: type) type {
        return ex.Immediate(Values);
    }
    pub fn bindInput(_: @This(), input: anytype) Bound(@typeInfo(@TypeOf(input)).pointer.child) {
        return ex.just(input.*);
    }
};
