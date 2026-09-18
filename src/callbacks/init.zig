//! Explicit state construction. Positional tuples follow field declaration order;
//! named initializers use Zig's normal coercion and default-field rules.
const diagnostics = @import("../detail/diagnostics.zig");

pub fn init(comptime Callback: type, args: anytype) Callback {
    comptime diagnostics.requireCallback(Callback, "capture");
    const A = @TypeOf(args);
    if (A == Callback) return args;
    if (@typeInfo(A) != .@"struct") @compileError("callback state must be a tuple or named initializer");
    if (!@typeInfo(A).@"struct".is_tuple or @typeInfo(A).@"struct".field_names.len == 0) {
        const fields = @typeInfo(Callback).@"struct";
        inline for (@typeInfo(A).@"struct".field_names) |name| {
            if (!@hasField(Callback, name)) @compileError("zigexec.capture: " ++ @typeName(Callback) ++ " has no field " ++ name);
        }
        var result: Callback = undefined;
        inline for (fields.field_names, fields.field_types, fields.field_attrs) |name, T, attrs| {
            if (@hasField(A, name)) {
                comptime diagnostics.checkType(T, @TypeOf(@field(args, name)), "zigexec.capture: " ++ @typeName(Callback) ++ "." ++ name);
                @field(result, name) = @field(args, name);
            } else if (attrs.defaultValue(T)) |value| {
                @field(result, name) = value;
            } else @compileError("zigexec.capture: " ++ @typeName(Callback) ++ " missing field " ++ name);
        }
        return result;
    }
    const fields = @typeInfo(Callback).@"struct";
    if (fields.field_names.len != args.len)
        @compileError("zigexec.capture: " ++ @typeName(Callback) ++ " positional state must supply every field; use a named initializer for defaults");
    var result: Callback = undefined;
    inline for (fields.field_names, fields.field_types, 0..) |name, T, i| {
        comptime diagnostics.checkType(T, @TypeOf(args[i]), "zigexec.capture: " ++ @typeName(Callback) ++ "." ++ name);
        @field(result, name) = args[i];
    }
    return result;
}
