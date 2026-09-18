pub fn CheckedResult(comptime F: type, comptime Args: type, comptime stage: []const u8) type {
    @import("diagnostics.zig").checkCall(F, Args, stage);
    return InvokeResult(F, Args);
}

pub fn Stored(comptime T: type) type {
    return if (@typeInfo(T) == .@"fn") *const T else T;
}

/// Specialize using upstream argument types, rather than an unspecialized
/// function's return_type (which is null for many useful generic callbacks).
pub fn InvokeResult(comptime F: type, comptime Args: type) type {
    if (@typeInfo(F) == .@"struct") {
        if (@hasDecl(F, "callTuple"))
            return @TypeOf(@call(.auto, F.callTuple, .{ @as(SelfArgument(F, "callTuple"), undefined), @as(Args, undefined) }));
        if (!@hasDecl(F, "call")) @compileError("callback needs pub fn call(self, ...) or callTuple(self, args)");
        return @TypeOf(@call(.auto, F.call, .{@as(SelfArgument(F, "call"), undefined)} ++ @as(Args, undefined)));
    }
    const Function = switch (@typeInfo(F)) {
        .pointer => |p| p.child,
        .@"fn" => F,
        else => @compileError("callback must be a function or callable struct"),
    };
    if (@typeInfo(Function) != .@"fn") @compileError("callback pointer must point to a function");
    if (@typeInfo(Function).@"fn".is_generic)
        @compileError("generic functions require their comptime identity: use ex.bind(function, .{})");
    return @typeInfo(Function).@"fn".return_type orelse
        @compileError("callback return type requires specialization; use ex.bind(function, .{})");
}

/// Dispatch against operation-owned storage, so a factory with pointer self
/// may safely lend captured buffers to its child sender.
fn SelfArgument(comptime F: type, comptime method: []const u8) type {
    const params = @typeInfo(@TypeOf(@field(F, method))).@"fn".param_types;
    if (params.len == 0) @compileError("call needs a self parameter");
    const First = params[0] orelse F;
    if (First != F and First != *F and First != *const F)
        @compileError("call self must be Callback, *Callback, or *const Callback");
    return First;
}

pub fn invokeStored(callback: anytype, args: anytype) InvokeResult(@typeInfo(@TypeOf(callback)).pointer.child, @TypeOf(args)) {
    const F = @typeInfo(@TypeOf(callback)).pointer.child;
    if (@typeInfo(F) == .@"struct") {
        if (@hasDecl(F, "callTuple")) {
            const receiver = if (comptime SelfArgument(F, "callTuple") == F) callback.* else callback;
            return @call(.auto, F.callTuple, .{ receiver, args });
        }
        const receiver = if (comptime SelfArgument(F, "call") == F) callback.* else callback;
        return @call(.auto, F.call, .{receiver} ++ args);
    }
    return @call(.auto, callback.*, args);
}

pub fn Payload(comptime T: type) type {
    return if (@typeInfo(T) == .error_union) @typeInfo(T).error_union.payload else T;
}

pub fn ReturnedValues(comptime T: type) type {
    return if (Payload(T) == void) @Tuple(&.{}) else @Tuple(&.{Payload(T)});
}

pub fn resultValues(value: anytype) ReturnedValues(@TypeOf(value)) {
    return if (@TypeOf(value) == void) .{} else .{value};
}
