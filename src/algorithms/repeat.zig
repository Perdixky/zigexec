const traits = @import("../detail/completion_traits.zig");
const std = @import("std");
const c = @import("../execution/protocol.zig");
const starts_on = @import("starts_on.zig");
const Trampoline = @import("../schedulers/trampoline.zig").TrampolineScheduler;

/// Like stdexec repeat_until: connect a trampoline-scheduled child, clean it up
/// on completion, then reconnect/start for another round or forward the terminal
/// result. The receiver environment is forwarded without an iteration scope.
pub fn Repeat(comptime S: type, comptime until: bool) type {
    const fields = @typeInfo(S.Values).@"struct".field_types;
    if (until) {
        if (fields.len != 1 or fields[0] != bool)
            @compileError("zigexec.repeatUntil: expected one bool completion value; true finishes, false repeats");
    } else if (fields.len != 0)
        @compileError("zigexec.repeat: expected an empty completion tuple; use then to discard values");
    const Bouncy = starts_on.StartsOn(Trampoline, S);
    return struct {
        sender: S,
        pub const Values = @Tuple(&.{});
        pub const can_error = traits.canError(S);
        const Self = @This();
        pub fn Operation(comptime R: type) type {
            return struct {
                sender: S,
                receiver: c.TypedReceiver(Values, R),
                child: c.OperationOf(Bouncy, *Op) = undefined,
                started: bool = false,
                child_connected: bool = true,
                const Op = @This();
                const Action = struct {
                    op: *Op,
                    result: union(enum) { again, value, err: anyerror, stopped },
                    pub fn run(self: @This()) void {
                        switch (self.result) {
                            .again => self.op.restart(),
                            .value => self.op.receiver.setValue(&.{}),
                            .err => |err| self.op.receiver.setError(err),
                            .stopped => self.op.receiver.setStopped(),
                        }
                    }
                };
                pub fn start(self: *Op) void {
                    std.debug.assert(!self.started);
                    self.started = true;
                    self.child.start();
                }
                pub fn getEnv(self: *Op) c.EnvOf(R) {
                    return self.receiver.getEnv();
                }
                pub fn cleanup(self: *Op, continuation: anytype) void {
                    if (!self.child_connected) return continuation.run();
                    self.child_connected = false;
                    c.cleanupOperation(&self.child, continuation);
                }
                fn restart(self: *Op) void {
                    c.connectChild(&self.child, starts_on.startsOn(Trampoline{}, self.sender), self);
                    self.child_connected = true;
                    self.child.start(); // Completion may reconnect child or destroy self.
                }
                pub fn setValue(self: *Op, values: *const S.Values) void {
                    const done = until and values.*[0];
                    self.cleanup(Action{ .op = self, .result = if (done) .value else .again });
                }
                pub fn setError(self: *Op, err: anyerror) void {
                    self.cleanup(Action{ .op = self, .result = .{ .err = err } });
                }
                pub fn setStopped(self: *Op) void {
                    self.cleanup(Action{ .op = self, .result = .stopped });
                }
            };
        }
        pub fn connectInto(self: Self, out: anytype, receiver: anytype) void {
            out.* = .{ .sender = self.sender, .receiver = .init(receiver) };
            c.connectChild(&out.child, starts_on.startsOn(Trampoline{}, self.sender), out);
        }
    };
}
