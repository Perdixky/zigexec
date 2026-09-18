//! Test synchronization is independent from the library's futex implementation.
const std = @import("std");
const ex = @import("zigexec");
pub const Empty = @Tuple(&.{});
pub const Ints = @Tuple(&.{i64});
pub fn double(value: i64) i64 {
    return value * 2;
}

pub const Event = struct {
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    signaled: bool = false,
    pub fn set(self: *@This()) void {
        self.mutex.lockUncancelable(std.testing.io);
        defer self.mutex.unlock(std.testing.io);
        self.signaled = true;
        self.condition.broadcast(std.testing.io);
    }
    pub fn wait(self: *@This()) void {
        self.mutex.lockUncancelable(std.testing.io);
        defer self.mutex.unlock(std.testing.io);
        while (!self.signaled) self.condition.waitUncancelable(std.testing.io, &self.mutex);
    }
};
pub const IntCapture = struct {
    values: ?Ints = null,
    err: ?anyerror = null,
    stopped: bool = false,
    completions: usize = 0,
    pub fn getEnv(_: *@This()) ex.Env {
        return .{ .allocator = std.testing.allocator };
    }
    pub fn setValue(self: *@This(), values: Ints) void {
        self.values = values;
        self.completions += 1;
    }
    pub fn setError(self: *@This(), err: anyerror) void {
        self.err = err;
        self.completions += 1;
    }
    pub fn setStopped(self: *@This()) void {
        self.stopped = true;
        self.completions += 1;
    }
};

/// Completes only via a stop callback, with no polling or scheduler.
pub const AwaitStop = struct {
    entered: ?*Event = null,
    pub const Values = Empty;
    pub const Operation = struct {
        receiver: ex.Receiver(Values),
        entered: ?*Event,
        callback: ex.StopCallback = .{},
        pub fn start(self: *@This()) void {
            const entered = self.entered;
            self.callback.init(self.receiver.env.stop_token, self, canceled);
            if (entered) |event| event.set();
        }
        fn canceled(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const receiver = self.receiver;
            self.callback.deinit();
            receiver.setStopped();
        }
    };
    pub fn connect(self: AwaitStop, receiver: ex.Receiver(Values)) Operation {
        return .{ .receiver = receiver, .entered = self.entered };
    }
};
