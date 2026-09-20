const Env = @import("environment.zig").Env;
const Completion = @import("completion.zig").Completion;
/// Explicit opt-in type erasure for legacy/custom runtime boundaries.
/// Built-in operation graphs use TypedReceiver instead.
/// Completion values borrow stable operation storage retained by its owner.
/// Completion may destroy operation storage.
pub fn Receiver(comptime Values: type) type {
    return struct {
        context: *anyopaque,
        value_fn: *const fn (*anyopaque, *const Values) void,
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
                @compileError("zigexec.receiver: provide getEnv() returning an Env");
            if (!@hasDecl(R, "setValue"))
                @compileError("zigexec.receiver: provide setValue(self, values: *const Values)");
            const value_params = @typeInfo(@TypeOf(R.setValue)).@"fn".param_types;
            if (value_params.len != 2 or (value_params[1] != null and value_params[1].? != *const Values))
                @compileError("zigexec.receiver: setValue must accept *const Values; copy values.* only when retaining an owned result");
            const Bridge = struct {
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
                .value_fn = Bridge.value,
                .error_fn = Bridge.err,
                .stopped_fn = Bridge.stopped,
                .env = ptr.getEnv().toDynamic(),
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
        pub fn complete(self: Self, result: *const Completion(Values)) void {
            switch (result.*) {
                .value => |*v| self.setValue(v),
                .err => |e| self.setError(e),
                .stopped => self.setStopped(),
            }
        }
    };
}

/// Statically dispatched receiver handle. Stores only R, never a vtable or Env.
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

/// Legacy custom senders can opt into the erased protocol. Built-in senders
/// always specialize their operation on the concrete receiver type.
pub fn OperationOf(comptime S: type, comptime R: type) type {
    return if (@TypeOf(S.Operation) == type) LegacyOperation(S, R) else S.Operation(R);
}
fn LegacyOperation(comptime S: type, comptime R: type) type {
    return struct {
        receiver: TypedReceiver(S.Values, R),
        child: S.Operation = undefined,
        pub fn cleanup(self: *@This(), continuation: anytype) void {
            @import("cleanup.zig").cleanupOperation(&self.child, continuation);
        }
        pub fn start(self: *@This()) void {
            self.child.start();
        }
    };
}
pub fn connectChild(out: anytype, sender: anytype, receiver: anytype) void {
    const S = @TypeOf(sender);
    const checked: *OperationOf(S, @TypeOf(receiver)) = out;
    if (@hasDecl(S, "connectInto")) {
        sender.connectInto(checked, receiver);
    } else {
        // Preserve arbitrary concrete receivers at a stable address, including
        // value adaptors used by joins. Only the legacy child sees erasure.
        checked.* = .{ .receiver = .init(receiver) };
        checked.child = sender.connect(Receiver(S.Values).init(&checked.receiver));
    }
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
