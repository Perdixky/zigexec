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
        pub fn Operation(comptime R: type) type {
            return struct {
                scope: *ex.CountingScope,
                receiver: ex.TypedReceiver(Empty, R),
                child: ex.Connection(Wrapped, *Op) = undefined,
                join_op: ex.meta.OperationOf(ex.CountingScope.Join, JoinReceiver) = undefined,
                result: ex.Completion(Empty) = undefined,
                canceled: std.atomic.Value(bool) = .init(false),
                callback: ex.StopCallbackFor(R) = .{},
                output: Empty = .{},
                const Op = @This();
                pub fn start(self: *Op) void {
                    self.callback.init(self.receiver.getEnv().stop_token, self, cancel);
                    self.child.start();
                }
                pub fn getEnv(self: *Op) ex.EnvOf(R) {
                    return self.receiver.getEnv();
                }
                pub fn setValue(self: *Op, _: *const Empty) void {
                    self.result = .{ .value = .{} };
                    self.producerDone();
                }
                pub fn setError(self: *Op, err: anyerror) void {
                    self.result = .{ .err = err };
                    self.producerDone();
                }
                pub fn setStopped(self: *Op) void {
                    self.result = .stopped;
                    self.producerDone();
                }
                fn producerDone(self: *Op) void {
                    // Producer is retired: it can no longer publish new children.
                    self.scope.close();
                    if (self.result != .value) _ = self.scope.requestStop();
                    self.join_op.start();
                }
                fn cancel(ctx: *anyopaque) void {
                    const self: *Op = @ptrCast(@alignCast(ctx));
                    self.canceled.store(true, .release);
                    _ = self.scope.requestStop();
                }
                const JoinReceiver = struct {
                    op: *Op,
                    // Cancellation cannot bypass cleanup or mask producer error.
                    pub fn getEnv(self: @This()) ex.UnstoppableEnv {
                        return self.op.receiver.getEnv().withStopToken(ex.NeverStopToken{});
                    }
                    pub fn setValue(self: @This(), _: *const Empty) void {
                        self.op.finish(null, false);
                    }
                    pub fn setError(self: @This(), err: anyerror) void {
                        self.op.finish(err, false);
                    }
                    pub fn setStopped(self: @This()) void {
                        self.op.finish(null, true);
                    }
                };
                fn finish(self: *Op, err: ?anyerror, stopped: bool) void {
                    self.callback.deinit();
                    const receiver = self.receiver;
                    if (self.result == .err) receiver.setError(self.result.err) else if (err) |e| receiver.setError(e) else if (self.result == .stopped or stopped or self.canceled.load(.acquire)) receiver.setStopped() else receiver.setValue(&self.output);
                }
            };
        }
        pub fn connectInto(self: @This(), out: anytype, receiver: anytype) void {
            out.* = .{ .scope = self.scope, .receiver = .init(receiver) };
            ex.connectInto(&out.child, self.scope.getToken().wrap(self.producer), out);
            self.scope.join().connectInto(&out.join_op, Operation(@TypeOf(receiver)).JoinReceiver{ .op = out });
        }
    };
}
pub fn runInScope(scope: *ex.CountingScope, producer: anytype) ex.Sender(RunInScope(@TypeOf(producer))) {
    return ex.asSender(RunInScope(@TypeOf(producer)){ .scope = scope, .producer = producer });
}
