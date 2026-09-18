const tuple = @import("../detail/tuple.zig");
const Immediate = @import("immediate.zig").Immediate;
pub fn just(values: anytype) Immediate(tuple.ValueTuple(@TypeOf(values))) {
    var result: tuple.ValueTuple(@TypeOf(values)) = undefined;
    if (comptime tuple.isTuple(@TypeOf(values))) {
        inline for (values, 0..) |v, i| result[i] = v;
    } else result[0] = values;
    return .{ .result = .{ .value = result } };
}
