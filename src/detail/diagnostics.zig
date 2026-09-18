//! Early, contextual diagnostics for mistakes visible from reflected signatures.
//! This is deliberately not a replacement for Zig's full coercion checker.
//! Value-dependent and complex structural coercions remain compiler-checked.
const std = @import("std");

pub fn requireCallback(comptime F: type, comptime stage: []const u8) void {
    if (@typeInfo(F) != .@"struct")
        @compileError("zigexec." ++ stage ++ ": expected a callback struct type; use ex.Fn(function) for a plain function");
    const method = if (@hasDecl(F, "callTuple")) "callTuple" else "call";
    if (!@hasDecl(F, method) or @typeInfo(@TypeOf(@field(F, method))) != .@"fn")
        @compileError("zigexec." ++ stage ++ ": " ++ @typeName(F) ++ " must declare pub fn call(self, ...) or callTuple(self, args)");
    const params = @typeInfo(@TypeOf(@field(F, method))).@"fn".param_types;
    if (params.len == 0) @compileError("zigexec." ++ stage ++ ": " ++ @typeName(F) ++ "." ++ method ++ " needs a self parameter");
    const Self = params[0] orelse F;
    if (Self != F and Self != *F and Self != *const F)
        @compileError("zigexec." ++ stage ++ ": " ++ @typeName(F) ++ "." ++ method ++ " self must be Callback, *Callback, or *const Callback");
}

pub fn checkCall(comptime F: type, comptime Args: type, comptime stage: []const u8) void {
    requireCallback(F, stage);
    if (@hasDecl(F, "__zigexec_function")) {
        checkParameters(@TypeOf(F.__zigexec_function), Args, 0, @typeName(F), stage);
    } else if (@hasDecl(F, "callTuple")) {
        checkParameters(@TypeOf(F.callTuple), @Tuple(&.{Args}), 1, @typeName(F) ++ ".callTuple", stage);
    } else {
        checkParameters(@TypeOf(F.call), Args, 1, @typeName(F) ++ ".call", stage);
    }
}

fn checkParameters(comptime Function: type, comptime Args: type, comptime skip: usize, comptime name: []const u8, comptime stage: []const u8) void {
    const FT = if (@typeInfo(Function) == .pointer) @typeInfo(Function).pointer.child else Function;
    const info = @typeInfo(FT).@"fn";
    const actual = @typeInfo(Args).@"struct".field_types;
    const expected = info.param_types[skip..];
    if (actual.len != expected.len)
        @compileError(std.fmt.comptimePrint("zigexec.{s}: {s} expects {d} upstream value(s), but upstream provides {d}", .{ stage, name, expected.len, actual.len }));
    for (expected, actual, 0..) |maybe_T, A, i| {
        if (maybe_T) |T| checkType(T, A, std.fmt.comptimePrint("zigexec.{s}: {s} upstream argument {d}", .{ stage, name, i }));
    }
}

pub fn checkType(comptime Expected: type, comptime Actual: type, comptime context: []const u8) void {
    if (definitelyIncompatible(Expected, Actual))
        @compileError(context ++ ": expected " ++ @typeName(Expected) ++ ", got " ++ @typeName(Actual));
}

// Reject provable mismatches, while leaving legal Zig coercions available.
fn definitelyIncompatible(comptime E: type, comptime A: type) bool {
    if (E == A or A == noreturn or @typeInfo(A) == .undefined) return false;
    const e = @typeInfo(E);
    const a = @typeInfo(A);
    if (e == .optional) return if (a == .null) false else definitelyIncompatible(e.optional.child, if (a == .optional) a.optional.child else A);
    if (e == .error_union) return if (a == .error_set) false else definitelyIncompatible(e.error_union.payload, if (a == .error_union) a.error_union.payload else A);
    return switch (e) {
        .int => |to| switch (a) {
            .comptime_int => false,
            .int => |from| if (to.signedness == from.signedness) to.bits < from.bits else to.signedness == .unsigned or to.bits <= from.bits,
            else => true,
        },
        .float => |to| switch (a) {
            .comptime_int, .comptime_float => false,
            .float => |from| to.bits < from.bits,
            else => true,
        },
        .bool => a != .bool,
        .pointer => a != .pointer,
        .@"enum" => a != .enum_literal,
        .void => a != .void,
        else => false,
    };
}

pub fn requireSender(comptime S: type, comptime F: type, comptime stage: []const u8) void {
    if (@typeInfo(S) == .@"struct") {
        if (@hasDecl(S, "Values") and @hasDecl(S, "Operation") and @hasDecl(S, "connect")) {
            if (@TypeOf(S.Values) == type and @TypeOf(S.Operation) == type and @typeInfo(@TypeOf(S.connect)) == .@"fn") {
                if (@typeInfo(S.Values) == .@"struct" and @typeInfo(S.Values).@"struct".is_tuple and @typeInfo(S.Operation) == .@"struct" and @hasDecl(S.Operation, "start")) return;
            }
        }
    }
    @compileError("zigexec." ++ stage ++ ": " ++ @typeName(F) ++ " must return a sender or !sender (Values, Operation.start, connect); got " ++ @typeName(S));
}
