const std = @import("std");
const c = @import("../execution/protocol.zig");

/// Reconnect the effect after each successful completion. One drain owner
/// serializes restarts; iteration-scope retirement queues work, so an old
/// completion handler exits before its operation storage is reconstructed.
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
            iteration: c.Scope = .{ .on_idle = iterationFinished },
            child: S.Operation = undefined,
            work: std.atomic.Value(usize) = .init(0),
            output: Values = .{},
            action: union(enum) { again, finish: c.Completion(Values) } = .again,
            started: bool = false,
            const Op = @This();
            pub fn start(self: *Op) void {
                std.debug.assert(!self.started);
                self.started = true;
                self.iteration.context = self;
                self.iteration.parent = self.receiver.env.scope;
                self.drain();
            }
            pub fn getEnv(self: *Op) c.Env {
                return self.receiver.env.withScope(&self.iteration);
            }
            fn drain(self: *Op) void {
                if (self.work.fetchAdd(1, .acq_rel) != 0) return;
                while (true) {
                    switch (self.action) {
                        .finish => |result| return switch (result) {
                            .value => self.receiver.setValue(&self.output),
                            .err => |err| self.receiver.setError(err),
                            .stopped => self.receiver.setStopped(),
                        },
                        .again => {},
                    }
                    if (self.receiver.env.stop_token.stopRequested())
                        return self.receiver.setStopped();
                    self.iteration.enter();
                    self.child = self.sender.connect(c.Receiver(S.Values).init(self));
                    self.child.start();
                    self.iteration.leave();
                    // A child scope may have retired inline or on another thread.
                    // The caller's scope entry protects the drain until it exits.
                    if (self.work.fetchSub(1, .acq_rel) == 1) return;
                }
            }
            pub fn setValue(self: *Op, values: *const S.Values) void {
                self.action = if (until and values.*[0]) .{ .finish = .{ .value = .{} } } else .again;
            }
            pub fn setError(self: *Op, err: anyerror) void {
                self.action = .{ .finish = .{ .err = err } };
            }
            pub fn setStopped(self: *Op) void {
                self.action = .{ .finish = .stopped };
            }
            fn iterationFinished(ctx: *anyopaque) void {
                const self: *Op = @ptrCast(@alignCast(ctx));
                self.drain();
            }
        };
        pub fn connect(self: Self, receiver: c.Receiver(Values)) Operation {
            return .{ .sender = self.sender, .receiver = receiver };
        }
    };
}
