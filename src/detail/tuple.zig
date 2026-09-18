/// Materialize tuple literals so e.g. just(.{42}) can cross a runtime boundary.
pub fn RuntimeTuple(comptime T: type) type {
    if (@typeInfo(T) != .@"struct" or !@typeInfo(T).@"struct".is_tuple)
        @compileError("just expects a tuple: just(.{value}) or just(.{})");
    const fields = @typeInfo(T).@"struct".field_types;
    var types: [fields.len]type = undefined;
    for (fields, 0..) |field, i| {
        types[i] = switch (@typeInfo(field)) {
            .comptime_int => i64,
            .comptime_float => f64,
            else => field,
        };
    }
    return @Tuple(&types);
}

/// Scalar shorthand for just(value); tuple input still represents many values.
pub fn ValueTuple(comptime T: type) type {
    return RuntimeTuple(if (isTuple(T)) T else @Tuple(&.{T}));
}

pub fn isTuple(comptime T: type) bool {
    // .{} has the empty anonymous struct type on Zig master.
    return @typeInfo(T) == .@"struct" and (@typeInfo(T).@"struct".is_tuple or T == @TypeOf(.{}));
}
