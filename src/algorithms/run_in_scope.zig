//! Higher-level producer policy, separate from counting and spawn: normal exit
//! closes and drains; producer failure/cancellation cancels children, then drains.
const std = @import("std");
const ex = @import("../root.zig");
const Empty = ex.Values(.{});

pub fn RunInScope(comptime S: type) type {
    if (S.Values != Empty) @compileError("zigexec.runInScope: producer must complete with no values");
    const Wrapped = ex.WithStopToken(S);
    return struct {
        scope: *ex.CountingScope,
        producer: S,
        pub const Values = Empty;
        pub const Operation = struct {
            scope: *ex.CountingScope,
            producer: S,
            receiver: ex.Receiver(Empty),
            child: ex.Connection(Wrapped) = undefined,
            join_op: ex.CountingScope.Join.Operation = undefined,
            result: ex.Completion(Empty) = undefined,
            canceled: std.atomic.Value(bool) = .init(false),
            callback: ex.StopCallback = .{},
            output: Empty = .{},
            const Op = @This();
            pub fn start(self: *Op) void {
                ex.Scope.acquire(self.receiver.env.scope);
                self.callback.init(self.receiver.env.stop_token, self, cancel);
                self.child = ex.connect(self.scope.getToken().wrap(self.producer), self);
                self.child.start();
            }
            pub fn getEnv(self: *Op) ex.Env {
                return self.receiver.env;
            }
            pub fn setValue(self: *Op, _: *const Empty) void {
                self.result = .{ .value = .{} };
            }
            pub fn setError(self: *Op, err: anyerror) void {
                self.result = .{ .err = err };
            }
            pub fn setStopped(self: *Op) void {
                self.result = .stopped;
            }
            pub fn setFinished(self: *Op) void {
                // Producer is retired: it can no longer publish new children.
                self.scope.close();
                if (self.result != .value) _ = self.scope.requestStop();
                self.join_op = self.scope.join().connect(.{
                    .context = self,
                    .value_fn = joined,
                    .error_fn = joinError,
                    .stopped_fn = joinStopped,
                    // Cancellation must not bypass cleanup or mask producer error.
                    .env = self.receiver.env.withStopToken(.{}),
                });
                self.join_op.start();
            }
            fn cancel(ctx: *anyopaque) void {
                const self: *Op = @ptrCast(@alignCast(ctx));
                const lifetime = self.receiver.env.scope;
                ex.Scope.acquire(lifetime);
                self.canceled.store(true, .release);
                _ = self.scope.requestStop();
                ex.Scope.release(lifetime);
            }
            fn joined(ctx: *anyopaque, _: *const Empty) void {
                const self: *Op = @ptrCast(@alignCast(ctx));
                self.finish(null, false);
            }
            fn joinError(ctx: *anyopaque, err: anyerror) void {
                const self: *Op = @ptrCast(@alignCast(ctx));
                self.finish(err, false);
            }
            fn joinStopped(ctx: *anyopaque) void {
                const self: *Op = @ptrCast(@alignCast(ctx));
                self.finish(null, true);
            }
            fn finish(self: *Op, err: ?anyerror, stopped: bool) void {
                self.callback.deinit();
                const receiver = self.receiver;
                if (self.result == .err) receiver.setError(self.result.err) else if (err) |e| receiver.setError(e) else if (self.result == .stopped or stopped or self.canceled.load(.acquire)) receiver.setStopped() else receiver.setValue(&self.output);
                ex.Scope.release(receiver.env.scope);
            }
        };
        pub fn connect(self: @This(), receiver: ex.Receiver(Empty)) Operation {
            return .{ .scope = self.scope, .producer = self.producer, .receiver = receiver };
        }
    };
}
pub fn runInScope(scope: *ex.CountingScope, producer: anytype) ex.Sender(RunInScope(@TypeOf(producer))) {
    return ex.asSender(RunInScope(@TypeOf(producer)){ .scope = scope, .producer = producer });
}
