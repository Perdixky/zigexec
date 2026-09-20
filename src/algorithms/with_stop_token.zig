const traits = @import("../detail/completion_traits.zig");
const std = @import("std");
const c = @import("../execution/protocol.zig");
const retainUnlessDone = @import("../detail/lifetime.zig").retainUnlessDone;

pub fn WithStopToken(comptime S: type) type {
    return struct {
        sender: S,
        token: c.StopToken,
        pub const Values = S.Values;
        pub const can_error = traits.canError(S);
        const Self = @This();
        pub fn Operation(comptime R: type) type {
            return struct {
                receiver: c.TypedReceiver(Values, R),
                token: c.StopToken,
                stop: c.StopSource = .{},
                upstream_stop: c.StopCallbackFor(R) = .{},
                added_stop: c.StopCallback = .{},
                child: c.OperationOf(S, *Op) = undefined,
                result: c.CompletionRef(Values) = undefined,
                remaining: std.atomic.Value(usize) = .init(2),
                started: bool = false,
                const Op = @This();
                pub fn cleanup(self: *Op, continuation: anytype) void {
                    c.cleanupOperation(&self.child, continuation);
                }
                pub fn start(self: *Op) void {
                    std.debug.assert(!self.started);
                    self.started = true;
                    self.upstream_stop.init(self.receiver.getEnv().stop_token, self, requestStop);
                    self.added_stop.init(self.token, self, requestStop);
                    self.child.start();
                    self.release();
                }
                fn requestStop(ctx: *anyopaque) void {
                    const self: *Op = @ptrCast(@alignCast(ctx));
                    if (!retainUnlessDone(&self.remaining)) return;
                    _ = self.stop.requestStop();
                    self.release();
                }
                pub fn getEnv(self: *Op) c.Env {
                    return self.receiver.getEnv().withStopToken(self.stop.token());
                }
                fn complete(self: *Op, result: c.CompletionRef(Values)) void {
                    self.result = result;
                    self.release();
                }
                fn release(self: *Op) void {
                    if (self.remaining.fetchSub(1, .acq_rel) != 1) return;
                    self.upstream_stop.deinit();
                    self.added_stop.deinit();
                    self.stop.deinit();
                    self.receiver.completeRef(self.result);
                }
                pub fn setValue(self: *Op, values: *const Values) void {
                    self.complete(.{ .value = values });
                }
                pub fn setError(self: *Op, err: anyerror) void {
                    self.complete(.{ .err = err });
                }
                pub fn setStopped(self: *Op) void {
                    self.complete(.stopped);
                }
            };
        }
        pub fn connectInto(self: Self, out: anytype, receiver: anytype) void {
            out.* = .{ .receiver = .init(receiver), .token = self.token };
            c.connectChild(&out.child, self.sender, out);
        }
    };
}

pub fn withStopToken(sender: anytype, token: c.StopToken) WithStopToken(@TypeOf(sender)) {
    return .{ .sender = sender, .token = token };
}
