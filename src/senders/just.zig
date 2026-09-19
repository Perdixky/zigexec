const tuple = @import("../detail/tuple.zig");
const ImmediateKind = @import("immediate.zig").ImmediateKind;
pub fn just(values: anytype) ImmediateKind(tuple.ValueTuple(@TypeOf(values)), .value) {
    var result: tuple.ValueTuple(@TypeOf(values)) = undefined;
    if (comptime tuple.isTuple(@TypeOf(values))) {
        inline for (values, 0..) |v, i| result[i] = v;
    } else result[0] = values;
    return .{ .result = .{ .value = result } };
}
