const traits = @import("../detail/completion_traits.zig");
const std = @import("std");
const c = @import("../execution/protocol.zig");
const Task = @import("../detail/task.zig").Task;
const Trampoline = @import("../schedulers/trampoline.zig").TrampolineScheduler;

/// Completion permits reconnecting the previous child in place. The shared trampoline
/// bounds recursion across heterogeneous/nested repeat operations as well.
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
                iteration: c.Scope = .{},
                child: c.OperationOf(S, *Op) = undefined,
                task: Task = .{ .run = execute },
                output: Values = .{},
                started: bool = false,
                first: bool = true,
                const Op = @This();
                const Action = struct {
                    op: *Op,
                    result: union(enum) { again, value, err: anyerror, stopped },
                    pub fn run(self: @This()) void {
                        switch (self.result) {
                            .again => self.op.enqueue(),
                            .value => self.op.receiver.setValue(&self.op.output),
                            .err => |err| self.op.receiver.setError(err),
                            .stopped => self.op.receiver.setStopped(),
                        }
                    }
                };
                pub fn start(self: *Op) void {
                    std.debug.assert(!self.started);
                    self.started = true;
                    self.enqueue();
                }
                pub fn getEnv(self: *Op) c.EnvOf(R) {
                    return self.receiver.getEnv().withScope(&self.iteration);
                }
                fn enqueue(self: *Op) void {
                    (Trampoline{}).submit(&self.task) catch unreachable;
                }
                fn execute(task: *Task) void {
                    const self: *Op = @fieldParentPtr("task", task);
                    if (self.receiver.getEnv().stop_token.stopRequested())
                        return self.receiver.setStopped();
                    if (!self.first) c.connectChild(&self.child, self.sender, self);
                    self.first = false;
                    self.child.start(); // Completion may reconnect child or destroy self.
                }
                pub fn setValue(self: *Op, values: *const S.Values) void {
                    const done = until and values.*[0];
                    self.iteration.complete(Action{ .op = self, .result = if (done) .value else .again });
                }
                pub fn setError(self: *Op, err: anyerror) void {
                    self.iteration.complete(Action{ .op = self, .result = .{ .err = err } });
                }
                pub fn setStopped(self: *Op) void {
                    self.iteration.complete(Action{ .op = self, .result = .stopped });
                }
            };
        }
        pub fn connectInto(self: Self, out: anytype, receiver: anytype) void {
            out.* = .{ .sender = self.sender, .receiver = .init(receiver) };
            c.connectChild(&out.child, self.sender, out);
        }
    };
}
