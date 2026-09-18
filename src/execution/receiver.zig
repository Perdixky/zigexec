const Env = @import("environment.zig").Env;
const Completion = @import("completion.zig").Completion;
/// The small type-erased boundary avoids recursive generic receiver types.
/// Values stay statically typed; no allocation is performed.
pub fn Receiver(comptime Values: type) type {
    return struct {
        context: *anyopaque,
        value_fn: *const fn (*anyopaque, Values) void,
        error_fn: *const fn (*anyopaque, anyerror) void,
        stopped_fn: *const fn (*anyopaque) void,
        env: Env,

        const Self = @This();

        pub fn init(ptr: anytype) Self {
            const P = @TypeOf(ptr);
            const info = @typeInfo(P);
            if (info != .pointer or info.pointer.size != .one or info.pointer.attrs.@"const")
                @compileError("receiver must be a mutable single-item pointer");
            const R = info.pointer.child;
            if (!@hasDecl(R, "getEnv"))
                @compileError("zigexec.receiver: provide getEnv() returning an Env with an explicit allocator");
            const Bridge = struct {
                fn value(ctx: *anyopaque, values: Values) void {
                    const receiver: P = @ptrCast(@alignCast(ctx));
                    receiver.setValue(values);
                }
                fn err(ctx: *anyopaque, e: anyerror) void {
                    const receiver: P = @ptrCast(@alignCast(ctx));
                    receiver.setError(e);
                }
                fn stopped(ctx: *anyopaque) void {
                    const receiver: P = @ptrCast(@alignCast(ctx));
                    receiver.setStopped();
                }
            };
            return .{
                .context = ptr,
                .value_fn = Bridge.value,
                .error_fn = Bridge.err,
                .stopped_fn = Bridge.stopped,
                .env = ptr.getEnv(),
            };
        }

        pub fn getEnv(self: Self) Env {
            return self.env;
        }

        pub fn setValue(self: Self, values: Values) void {
            self.value_fn(self.context, values);
        }
        pub fn setError(self: Self, err: anyerror) void {
            self.error_fn(self.context, err);
        }
        pub fn setStopped(self: Self) void {
            self.stopped_fn(self.context);
        }
        pub fn complete(self: Self, result: Completion(Values)) void {
            switch (result) {
                .value => |v| self.setValue(v),
                .err => |e| self.setError(e),
                .stopped => self.setStopped(),
            }
        }
    };
}
