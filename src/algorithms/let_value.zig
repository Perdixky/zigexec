//! Uniform continuation dispatch. Factory identity is a comptime type; sender
//! and expression operands retain their runtime captures without type erasure.
const Let = @import("detail/let.zig").Let;
const Scope = @import("detail/let_scope.zig").Scope;
const initCallback = @import("../callbacks/init.zig").init;

pub const Kind = enum { factory, body };
pub fn kind(comptime T: type) Kind {
    if (@typeInfo(T) == .@"struct") {
        if (@hasDecl(T, "__zigexec_expression") or
            (@hasDecl(T, "Values") and @hasDecl(T, "Operation") and @hasDecl(T, "connect"))) return .body;
        if (@hasDecl(T, "call") or @hasDecl(T, "callTuple")) return .factory;
    }
    @compileError("zigexec.letValue: expected a sender factory type, a sender value, or an upstream() subchain");
}

pub fn LetValue(comptime S: type, comptime Target: type) type {
    return switch (kind(Target)) {
        .factory => Let(S, Target, .value),
        .body => Scope(S, Target),
    };
}

/// A type operand is implicitly comptime in Zig, while a sender/expression
/// operand can carry runtime state. args initializes only factory callbacks.
pub fn capture(target: anytype, args: anytype) if (@TypeOf(target) == type) target else @TypeOf(target) {
    if (@TypeOf(target) == type) {
        if (comptime kind(target) != .factory)
            @compileError("zigexec.letValue: pass a constructed sender/subchain value; only a factory callback is passed as a type");
        return initCallback(target, args);
    }
    if (comptime kind(@TypeOf(target)) == .factory)
        @compileError("zigexec.letValue: pass the factory type as the first argument and its captures as the second");
    const A = @TypeOf(args);
    if (@typeInfo(A) != .@"struct" or @typeInfo(A).@"struct".field_names.len != 0)
        @compileError("zigexec.letValue: sender/subchain operands require .{} as args; captures belong to factory callbacks");
    return target;
}

pub fn letValue(sender: anytype, target: anytype, args: anytype) LetValue(@TypeOf(sender), if (@TypeOf(target) == type) target else @TypeOf(target)) {
    const state = capture(target, args);
    return switch (comptime kind(@TypeOf(state))) {
        .factory => .{ .sender = sender, .callback = state },
        .body => .{ .sender = sender, .body = state },
    };
}
