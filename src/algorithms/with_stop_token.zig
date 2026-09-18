const std = @import("std");
const c = @import("../execution/protocol.zig");
const retainUnlessDone = @import("../detail/lifetime.zig").retainUnlessDone;

pub fn WithStopToken(comptime S: type) type {
    return struct {
        sender: S,
        token: c.StopToken,
        pub const Values = S.Values;
        const Self = @This();
        pub const Operation = struct {
            sender: S,
            receiver: c.Receiver(Values),
            token: c.StopToken,
            stop: c.StopSource = .{},
            upstream_stop: c.StopCallback = .{},
            added_stop: c.StopCallback = .{},
            child: S.Operation = undefined,
            result: c.Completion(Values) = undefined,
            remaining: std.atomic.Value(usize) = .init(2),
            started: bool = false,
            const Op = @This();
            pub fn start(self: *Op) void {
                std.debug.assert(!self.started);
                self.started = true;
                self.upstream_stop.init(self.receiver.env.stop_token, self, requestStop);
                self.added_stop.init(self.token, self, requestStop);
                self.child = self.sender.connect(c.Receiver(Values).init(self));
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
                return self.receiver.env.withStopToken(self.stop.token());
            }
            fn complete(self: *Op, result: c.Completion(Values)) void {
                self.result = result;
                self.release();
            }
            fn release(self: *Op) void {
                if (self.remaining.fetchSub(1, .acq_rel) != 1) return;
                self.upstream_stop.deinit();
                self.added_stop.deinit();
                self.stop.deinit();
                self.receiver.complete(self.result);
            }
            pub fn setValue(self: *Op, values: Values) void {
                self.complete(.{ .value = values });
            }
            pub fn setError(self: *Op, err: anyerror) void {
                self.complete(.{ .err = err });
            }
            pub fn setStopped(self: *Op) void {
                self.complete(.stopped);
            }
        };
        pub fn connect(self: Self, receiver: c.Receiver(Values)) Operation {
            return .{ .sender = self.sender, .receiver = receiver, .token = self.token };
        }
    };
}

pub fn withStopToken(sender: anytype, token: c.StopToken) WithStopToken(@TypeOf(sender)) {
    return .{ .sender = sender, .token = token };
}
