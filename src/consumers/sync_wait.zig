const c = @import("../execution/protocol.zig");
const RunLoop = @import("../schedulers/run_loop.zig").RunLoop;
const StartScheduler = @import("../schedulers/start_scheduler.zig");

/// Wait for completion AND retirement while driving a caller-thread run loop.
/// Supplies getStartScheduler when absent, so asynchronous join can resume here.
pub fn syncWait(sender: anytype, env: c.Env) anyerror!?@TypeOf(sender).Values {
    const Values = @TypeOf(sender).Values;
    const State = struct {
        loop: *RunLoop,
        result: c.CompletionRef(Values) = undefined,
        env: c.Env,
        pub fn getEnv(self: *@This()) c.Env {
            return self.env;
        }
        pub fn setFinished(self: *@This()) void {
            self.loop.finish();
        }
        pub fn setValue(self: *@This(), values: *const Values) void {
            self.result = .{ .value = values };
        }
        pub fn setError(self: *@This(), err: anyerror) void {
            self.result = .{ .err = err };
        }
        pub fn setStopped(self: *@This()) void {
            self.result = .stopped;
        }
    };
    var loop: RunLoop = .{};
    const scheduler = loop.getScheduler();
    var wait_env = env;
    if (wait_env.start_scheduler == null) wait_env.start_scheduler = StartScheduler.init(&scheduler);
    var state: State = .{ .loop = &loop, .env = wait_env };
    var operation = c.connect(sender, &state);
    operation.start();
    loop.run();
    return switch (state.result) {
        .value => |values| values.*,
        .err => |err| err,
        .stopped => null,
    };
}
