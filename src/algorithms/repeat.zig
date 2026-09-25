const traits = @import("../detail/completion_traits.zig");
const StartGuard = @import("../detail/start_guard.zig").StartGuard;
const std = @import("std");
const c = @import("../execution/protocol.zig");
const Task = @import("../detail/task.zig").Task;
const Trampoline = @import("../schedulers/trampoline.zig").TrampolineScheduler;

/// How many rounds that complete synchronously may run on one trampoline frame
/// before the loop hands control back to the trampoline's FIFO. Rounds are
/// always entered through the trampoline; this only bounds how many may nest
/// inside a single `execute` call, so the C stack stays flat however many
/// iterations a chain performs. Tunable for workloads that prefer fewer hops.
pub var inline_rounds: usize = 16;

/// Like stdexec repeat_until: start each round, clean the child up on
/// completion, then reconnect/start another round or forward the terminal
/// result. The receiver environment is forwarded without an iteration scope.
/// The round's task is embedded here instead of connecting a startsOn
/// (trampoline) wrapper, so a round builds no per-round scheduler op.
///
/// A round that completes synchronously is consumed by the `execute` call that
/// started it, so an inline chain pays no per-round trampoline hop. A round
/// that suspends completes later, off the loop's stack; that completion cleans
/// up and owns the response itself. `inline` tells the two apart: it is true
/// only while `child.start()` is on the stack.
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
                /// Advances on every child completion. `execute` snapshots this
                /// across `child.start()`; an unchanged value means the round is
                /// still in flight and will respond from its own completion.
                completions: usize = 0,
                /// True exactly while `child.start()` is on the stack. The
                /// completion that arrives then must not drive its own
                /// response; the loop that started it does.
                inline_round: bool = false,
                /// The terminal outcome of the round that just completed. Stays
                /// `.none` while the loop should keep iterating.
                terminal: Outcome = .none,
                const Op = @This();

                const Outcome = union(enum) {
                    none,
                    value,
                    err: anyerror,
                    stopped,
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
                    // How many rounds this frame may run before resubmitting.
                    // Clamped to at least one so a zero budget still makes
                    // progress rather than spinning through the trampoline.
                    var budget = @max(inline_rounds, 1);
                    while (true) {
                        // Stop is observed before every round, including the
                        // first, whose child was connected eagerly and still
                        // needs cleanup.
                        if (self.receiver.getEnv().stop_token.stopRequested()) {
                            self.deliver(.stopped);
                            return;
                        }
                        if (!self.child_connected) {
                            c.connectChild(&self.child, self.sender, self);
                            self.child_connected = true;
                        }
                        const before = self.completions;
                        self.inline_round = true;
                        self.child.start(); // May complete inline, or destroy self.
                        self.inline_round = false;
                        // The round suspended or completed on another thread.
                        // Its own completion already delivered the terminal
                        // result or resubmitted the next round.
                        if (self.completions == before) return;
                        // Terminal: the round already detached its child, so the
                        // loop only has to deliver. This may destroy the
                        // operation, so nothing may be read afterwards.
                        if (self.terminal != .none) {
                            self.deliver(self.terminal);
                            return;
                        }
                        // An inline round that keeps going: the completion
                        // detached the child, so reconnect on the next pass.
                        budget -= 1;
                        if (budget == 0) break;
                    }
                    // Budget exhausted: hand the stack back to the trampoline
                    // rather than growing this one without bound.
                    self.schedule();
                }

                /// Detach the child, then hand the result to the receiver. The
                /// detach runs first so the receiver may reclaim this storage.
                fn deliver(self: *Op, outcome: Outcome) void {
                    const Forward = struct {
                        op: *Op,
                        outcome: Outcome,
                        pub fn run(action: @This()) void {
                            const receiver = action.op.receiver;
                            switch (action.outcome) {
                                .none => action.op.schedule(),
                                .value => receiver.setValue(&.{}),
                                .err => |err| receiver.setError(err),
                                .stopped => receiver.setStopped(),
                            }
                        }
                    };
                    self.cleanup(Forward{ .op = self, .outcome = outcome });
                }

                /// Completion entry point. Every completed round detaches its
                /// child here, so the next round reconnects into the same
                /// storage. A terminal outcome is delivered now when the round
                /// was asynchronous, and recorded for the loop when it was not
                /// (the loop delivers it once it stops iterating).
                fn settle(self: *Op, outcome: Outcome) void {
                    self.completions += 1;
                    if (outcome != .none) self.terminal = outcome;
                    const Forward = struct {
                        op: *Op,
                        outcome: Outcome,
                        on_stack: bool,
                        pub fn run(action: @This()) void {
                            const op = action.op;
                            if (action.on_stack) return; // The loop owns delivery.
                            switch (action.outcome) {
                                .none => continue_round(op),
                                .value => op.receiver.setValue(&.{}),
                                .err => |err| op.receiver.setError(err),
                                .stopped => op.receiver.setStopped(),
                            }
                        }
                    };
                    self.cleanup(Forward{ .op = self, .outcome = outcome, .on_stack = self.inline_round });
                }

                fn continue_round(self: *Op) void {
                    self.schedule();
                }

                pub fn setValue(self: *Op, values: *const S.Values) void {
                    const done = until and values.*[0];
                    self.settle(if (done) .value else .none);
                }
                pub fn setError(self: *Op, err: anyerror) void {
                    self.settle(.{ .err = err });
                }
                pub fn setStopped(self: *Op) void {
                    self.settle(.stopped);
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
