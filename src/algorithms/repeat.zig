const traits = @import("../detail/completion_traits.zig");
const StartGuard = @import("../detail/start_guard.zig").StartGuard;
const std = @import("std");
const c = @import("../execution/protocol.zig");
const Task = @import("../detail/task.zig").Task;
const Trampoline = @import("../schedulers/trampoline.zig").TrampolineScheduler;

/// Like stdexec repeat_until: start each round through the trampoline, clean
/// the child up on completion, then reconnect/start another round or forward
/// the terminal result. The receiver environment is forwarded without an
/// iteration scope. The round's task is embedded here instead of connecting a
/// startsOn(trampoline) wrapper, so a round builds no per-round scheduler op.
pub fn Repeat(comptime S: type, comptime until: bool) type {
    const fields = @typeInfo(S.Values).@"struct".field_types;
    if (until) {
        if (fields.len != 1 or fields[0] != bool)
            @compileError("zigexec.repeatUntil: expected one bool completion value; true finishes, false repeats");
    } else if (fields.len != 0)
        @compileError("zigexec.repeat: expected an empty completion tuple; use then to discard values");
    return struct {
        sender: S,
        pub const Values = @Tuple(&.{});
        pub const can_error = traits.canError(S);
        const Self = @This();
        pub fn Operation(comptime R: type) type {
            return struct {
                sender: S,
                receiver: c.TypedReceiver(Values, R),
                task: Task = .{ .run = execute },
                child: c.OperationOf(S, *Op) = undefined,
                started: StartGuard = .{},
                child_connected: bool = false,
                const Op = @This();
                const Action = struct {
                    op: *Op,
                    result: union(enum) { again, value, err: anyerror, stopped },
                    pub fn run(self: @This()) void {
                        switch (self.result) {
                            .again => self.op.schedule(),
                            .value => self.op.receiver.setValue(&.{}),
                            .err => |err| self.op.receiver.setError(err),
                            .stopped => self.op.receiver.setStopped(),
                        }
                    }
                };
                pub fn start(self: *Op) void {
                    self.started.begin();
                    self.schedule();
                }
                pub fn getEnv(self: *Op) c.EnvOf(R) {
                    return self.receiver.getEnv();
                }
                pub fn cleanup(self: *Op, continuation: anytype) void {
                    if (!self.child_connected) return continuation.run();
                    self.child_connected = false;
                    c.cleanupOperation(&self.child, continuation);
                }
                fn schedule(self: *Op) void {
                    (Trampoline{}).submit(&self.task) catch |err| switch (err) {};
                }
                fn execute(task: *Task) void {
                    const self: *Op = @fieldParentPtr("task", task);
                    // Stop is observed before every round, including the first,
                    // whose child was connected eagerly and still needs cleanup.
                    if (self.receiver.getEnv().stop_token.stopRequested())
                        return self.cleanup(Action{ .op = self, .result = .stopped });
                    if (!self.child_connected) {
                        c.connectChild(&self.child, self.sender, self);
                        self.child_connected = true;
                    }
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
        pub fn connectInto(self: Self, out: anytype, r: anytype) void {
            // Like stdexec, the first child is connected with the repeat itself.
            out.* = .{ .sender = self.sender, .receiver = .init(r) };
            c.connectChild(&out.child, self.sender, out);
            out.child_connected = true;
        }
    };
}
