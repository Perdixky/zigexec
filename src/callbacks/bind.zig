const meta = @import("../meta.zig");
const RuntimeTuple = @import("../detail/tuple.zig").RuntimeTuple;

/// Statically retain a function's identity and bind a prefix of runtime values.
/// Remaining arguments come from the upstream sender, with generic specialization.
pub fn Bind(comptime function: anytype, comptime prefix_types: anytype) type {
    return Bound(function, meta.Values(prefix_types));
}

fn Bound(comptime function: anytype, comptime Prefix: type) type {
    return struct {
        prefix: Prefix,
        pub fn callTuple(self: @This(), args: anytype) @TypeOf(@call(.auto, function, self.prefix ++ args)) {
            return @call(.auto, function, self.prefix ++ args);
        }
    };
}

pub fn bind(comptime function: anytype, prefix: anytype) Bind(function, @typeInfo(RuntimeTuple(@TypeOf(prefix))).@"struct".field_types) {
    return .{ .prefix = prefix };
}
