const std = @import("std");
const c = @import("../execution/protocol.zig");

/// Reconnect the effect after each successful completion. One drain owner
/// serializes restarts; inline completion queues work instead of recursing.
pub fn Repeat(comptime S: type, comptime until: bool) type {
    const fields = @typeInfo(S.Values).@"struct".field_types;
    if (until) {
        if (fields.len != 1 or fields[0] != bool)
            @compileError("zigexec.repeatEffectUntil: expected one bool completion value; true finishes, false repeats");
    } else if (fields.len != 0)
        @compileError("zigexec.repeatEffect: expected an empty completion tuple; use then to discard values");
    return struct {
        sender: S,
        pub const Values = @Tuple(&.{});
        const Self = @This();
        pub const Operation = struct {
            sender: S,
            receiver: c.Receiver(Values),
            child: S.Operation = undefined,
            work: std.atomic.Value(usize) = .init(0),
            action: union(enum) { again, finish: c.Completion(Values) } = .again,
            started: bool = false,
            const Op = @This();
            pub fn start(self: *Op) void {
                std.debug.assert(!self.started);
                self.started = true;
                self.drain();
            }
            pub fn getEnv(self: *Op) c.Env {
                return self.receiver.env;
            }
            fn drain(self: *Op) void {
                if (self.work.fetchAdd(1, .acq_rel) != 0) return;
                while (true) {
                    switch (self.action) {
                        .finish => |result| return self.receiver.complete(result),
                        .again => {},
                    }
                    if (self.receiver.env.stop_token.stopRequested())
                        return self.receiver.setStopped();
                    self.child = self.sender.connect(c.Receiver(S.Values).init(self));
                    self.child.start();
                    // A child may have completed inline or on another thread.
                    // Releasing the drain owner is the final access when idle:
                    // a concurrent completion may immediately destroy this op.
                    if (self.work.fetchSub(1, .acq_rel) == 1) return;
                }
            }
            pub fn setValue(self: *Op, values: S.Values) void {
                self.action = if (until and values[0]) .{ .finish = .{ .value = .{} } } else .again;
                self.drain();
            }
            pub fn setError(self: *Op, err: anyerror) void {
                self.action = .{ .finish = .{ .err = err } };
                self.drain();
            }
            pub fn setStopped(self: *Op) void {
                self.action = .{ .finish = .stopped };
                self.drain();
            }
        };
        pub fn connect(self: Self, receiver: c.Receiver(Values)) Operation {
            return .{ .sender = self.sender, .receiver = receiver };
        }
    };
}
