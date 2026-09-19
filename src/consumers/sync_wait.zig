const c = @import("../execution/protocol.zig");
const sync = @import("../detail/sync.zig");

/// Wait for completion AND quiescence. The result is borrowed within the root
/// connection until its execution entries finish, then copied out once.
pub fn syncWait(sender: anytype, env: c.Env) anyerror!?@TypeOf(sender).Values {
    const Values = @TypeOf(sender).Values;
    const State = struct {
        mutex: sync.Mutex = .{},
        ready: sync.Condition = .{},
        done: bool = false,
        result: c.CompletionRef(Values) = undefined,
        env: c.Env,
        const Self = @This();
        pub fn getEnv(self: *Self) c.Env {
            return self.env;
        }
        pub fn setFinished(self: *Self) void {
            self.mutex.lock();
            self.done = true;
            self.ready.signal();
            self.mutex.unlock();
        }
        pub fn setValue(self: *Self, values: *const Values) void {
            self.result = .{ .value = values };
        }
        pub fn setError(self: *Self, err: anyerror) void {
            self.result = .{ .err = err };
        }
        pub fn setStopped(self: *Self) void {
            self.result = .stopped;
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
        .value => |values| values.*,
        .err => |err| err,
        .stopped => null,
    };
}
