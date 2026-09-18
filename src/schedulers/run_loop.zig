const std = @import("std");
const Queue = @import("../detail/queue.zig").Queue;
const QueueScheduler = @import("queue.zig").QueueScheduler;
/// Keep the loop at a stable address while schedulers exist. Run it on a
/// dedicated thread, or use connect/start and drive run() on the current thread.
pub const RunLoop = struct {
    pub const Scheduler = QueueScheduler;
    queue: Queue = .{},

    pub fn getScheduler(self: *RunLoop) QueueScheduler {
        return .{ .queue = &self.queue };
    }
    pub fn run(self: *RunLoop) void {
        self.queue.run();
    }
    /// Close submissions, drain queued work, and let run() return.
    pub fn finish(self: *RunLoop) void {
        self.queue.close();
    }
};
