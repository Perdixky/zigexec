//! Public compile-time queries. These analyze types; they never execute work.
const c = @import("detail/callable.zig");

/// Build a success/argument tuple from a list of types: Values(.{i64, bool}).
pub fn Values(comptime types: anytype) type {
    var fields: [types.len]type = undefined;
    for (types, 0..) |T, i| {
        if (@TypeOf(T) != type) @compileError("Values expects a list of types, e.g. .{ i64, bool }");
        fields[i] = T;
    }
    return @Tuple(&fields);
}

pub fn ValuesOf(comptime S: type) type {
    return S.Values;
}

/// The sole successful value; use ValuesOf for zero or multiple values.
pub fn ValueOf(comptime S: type) type {
    const fields = @typeInfo(S.Values).@"struct".field_types;
    if (fields.len != 1) @compileError("ValueOf requires exactly one value; use ValuesOf for the complete tuple");
    return fields[0];
}

pub fn OperationOf(comptime S: type) type {
    return S.Operation;
}

pub fn WaitResult(comptime S: type) type {
    return anyerror!?S.Values;
}

/// Specialize a known function with argument TYPES, including generic factories.
/// Arguments must be runtime parameters; value-dependent comptime arguments need
/// explicit specialization in a wrapper. No function body is executed here.
pub fn ReturnOf(comptime function: anytype, comptime argument_types: anytype) type {
    return @TypeOf(@call(.auto, function, @as(Values(argument_types), undefined)));
}

/// Infer an ordinary/callable-struct callback using a tuple of argument types.
pub fn CallResult(comptime Callback: type, comptime Args: type) type {
    return c.InvokeResult(c.Stored(Callback), Args);
}
