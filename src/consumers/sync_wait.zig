const c = @import("../execution/protocol.zig");
const sync = @import("../detail/sync.zig");

/// Block the calling OS thread. The scheduler must make progress independently:
/// don't wait on work queued to a run loop you aren't driving, or exhaust a
/// pool by blocking all its workers on more work for that same pool.
/// The caller supplies the execution environment, including its allocator.
/// Neither the environment nor allocations returned as results are owned here.
/// Success is a tuple, cancellation is null, errors use Zig error propagation.
pub fn syncWait(sender: anytype, env: c.Env) anyerror!?@TypeOf(sender).Values {
    const Values = @TypeOf(sender).Values;
    const State = struct {
        mutex: sync.Mutex = .{},
        ready: sync.Condition = .{},
        done: bool = false,
        result: c.Completion(Values) = undefined,
        env: c.Env,
        const Self = @This();
        pub fn getEnv(self: *Self) c.Env {
            return self.env;
        }
        fn complete(self: *Self, result: c.Completion(Values)) void {
            self.mutex.lock();
            self.result = result;
            self.done = true;
            self.ready.signal();
            self.mutex.unlock();
        }
        pub fn setValue(self: *Self, values: Values) void {
            self.complete(.{ .value = values });
        }
        pub fn setError(self: *Self, err: anyerror) void {
            self.complete(.{ .err = err });
        }
        pub fn setStopped(self: *Self) void {
            self.complete(.stopped);
        }
    };
    var state: State = .{ .env = env };
    var operation = c.connect(sender, &state);
    operation.start();
    state.mutex.lock();
    while (!state.done) state.ready.waitForSignal(&state.mutex);
    const result = state.result;
    state.mutex.unlock();
    return switch (result) {
        .value => |values| values,
        .err => |err| err,
        .stopped => null,
    };
}
