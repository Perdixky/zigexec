const Env = @import("environment.zig").Env;
const Completion = @import("completion.zig").Completion;
/// The small type-erased boundary avoids recursive generic receiver types.
/// Completion values borrow stable operation storage until the execution scope
/// retires. A root receiver may reclaim its connection only in setFinished.
pub fn Receiver(comptime Values: type) type {
    return struct {
        context: *anyopaque,
        value_fn: *const fn (*anyopaque, *const Values) void,
        error_fn: *const fn (*anyopaque, anyerror) void,
        stopped_fn: *const fn (*anyopaque) void,
        env: Env,
        finished_fn: ?*const fn (*anyopaque) void = null,

        const Self = @This();

        pub fn init(ptr: anytype) Self {
            const P = @TypeOf(ptr);
            const info = @typeInfo(P);
            if (info != .pointer or info.pointer.size != .one or info.pointer.attrs.@"const")
                @compileError("receiver must be a mutable single-item pointer");
            const R = info.pointer.child;
            if (!@hasDecl(R, "getEnv"))
                @compileError("zigexec.receiver: provide getEnv() returning an Env");
            if (!@hasDecl(R, "setValue"))
                @compileError("zigexec.receiver: provide setValue(self, values: *const Values)");
            const value_params = @typeInfo(@TypeOf(R.setValue)).@"fn".param_types;
            if (value_params.len != 2 or (value_params[1] != null and value_params[1].? != *const Values))
                @compileError("zigexec.receiver: setValue must accept *const Values; copy values.* only when retaining an owned result");
            const Bridge = struct {
                fn finished(ctx: *anyopaque) void {
                    if (@hasDecl(R, "setFinished")) {
                        const receiver: P = @ptrCast(@alignCast(ctx));
                        receiver.setFinished();
                    }
                }
                fn value(ctx: *anyopaque, values: *const Values) void {
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
                .finished_fn = Bridge.finished,
                .value_fn = Bridge.value,
                .error_fn = Bridge.err,
                .stopped_fn = Bridge.stopped,
                .env = ptr.getEnv(),
            };
        }

        pub fn getEnv(self: Self) Env {
            return self.env;
        }

        pub fn setValue(self: Self, values: *const Values) void {
            self.value_fn(self.context, values);
        }
        pub fn setError(self: Self, err: anyerror) void {
            self.error_fn(self.context, err);
        }
        pub fn setStopped(self: Self) void {
            self.stopped_fn(self.context);
        }
        pub fn completeRef(self: Self, result: @import("completion_ref.zig").CompletionRef(Values)) void {
            switch (result) {
                .value => |v| self.setValue(v),
                .err => |err| self.setError(err),
                .stopped => self.setStopped(),
            }
        }
        pub fn setFinished(self: Self) void {
            if (self.finished_fn) |f| f(self.context);
        }
        pub fn complete(self: Self, result: *const Completion(Values)) void {
            switch (result.*) {
                .value => |*v| self.setValue(v),
                .err => |e| self.setError(e),
                .stopped => self.setStopped(),
            }
        }
    };
}
