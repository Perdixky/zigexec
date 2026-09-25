const Env = @import("environment.zig").Env;
const Completion = @import("completion.zig").Completion;
/// Statically dispatched receiver handle. Stores only R, never a vtable or Env.
/// Completion values borrow stable operation storage retained by its owner;
/// completion may destroy the operation.
pub fn TypedReceiver(comptime Values: type, comptime R: type) type {
    return struct {
        target: R,
        const Self = @This();
        pub fn init(target: R) Self {
            const T = if (@typeInfo(R) == .pointer) @typeInfo(R).pointer.child else R;
            if (!@hasDecl(T, "getEnv"))
                @compileError("zigexec.receiver: provide getEnv() returning an Env");
            if (!@hasDecl(T, "setValue"))
                @compileError("zigexec.receiver: provide setValue(self, values: *const Values)");
            const params = @typeInfo(@TypeOf(T.setValue)).@"fn".param_types;
            if (params.len != 2 or (params[1] != null and params[1].? != *const Values))
                @compileError("zigexec.receiver: setValue must accept *const Values; copy values.* only when retaining an owned result");
            return .{ .target = target };
        }
        pub fn getEnv(self: Self) EnvOf(R) {
            return self.target.getEnv();
        }
        pub fn setValue(self: Self, values: *const Values) void {
            self.target.setValue(values);
        }
        pub fn setError(self: Self, err: anyerror) void {
            self.target.setError(err);
        }
        pub fn setStopped(self: Self) void {
            self.target.setStopped();
        }
        pub fn completeRef(self: Self, result: @import("completion_ref.zig").CompletionRef(Values)) void {
            switch (result) {
                .value => |v| self.setValue(v),
                .err => |e| self.setError(e),
                .stopped => self.setStopped(),
            }
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

/// Every sender specializes its operation on the concrete receiver type; the
/// node state (F, schedulers, scope) is statically visible inside it.
pub fn OperationOf(comptime S: type, comptime R: type) type {
    return S.Operation(R);
}

/// Connect `sender` into caller-provided storage at its final address. The
/// address is stable for the whole operation lifetime, so a child may hold a
/// pointer to its parent's state.
pub fn connectChild(out: anytype, sender: anytype, receiver: anytype) void {
    const S = @TypeOf(sender);
    const checked: *OperationOf(S, @TypeOf(receiver)) = out;
    sender.connectInto(checked, receiver);
}

pub fn EnvOf(comptime R: type) type {
    const T = if (@typeInfo(R) == .pointer) @typeInfo(R).pointer.child else R;
    return @typeInfo(@TypeOf(T.getEnv)).@"fn".return_type.?;
}
pub fn StopCallbackFor(comptime R: type) type {
    const Token = @FieldType(EnvOf(R), "stop_token");
    return if (Token == @import("environment.zig").NeverStopToken) NoStopCallback else @import("../cancellation/callback.zig");
}
const NoStopCallback = struct {
    pub fn init(_: *@This(), _: @import("environment.zig").NeverStopToken, _: *anyopaque, _: *const fn (*anyopaque) void) void {}
    pub fn deinit(_: *@This()) void {}
};
