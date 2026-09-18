const std = @import("std");
const Queue = @import("../detail/queue.zig").Queue;
const QueueScheduler = @import("queue.zig").QueueScheduler;
/// A fixed-size pool, allocated once at a stable address. Complete operations
/// before deinit. Never deinit from one of this pool's workers.
pub const ThreadPool = struct {
    pub const Scheduler = QueueScheduler;
    allocator: std.mem.Allocator,
    threads: []std.Thread,
    queue: Queue = .{},

    pub fn init(allocator: std.mem.Allocator, thread_count: usize) !*ThreadPool {
        if (thread_count == 0) return error.InvalidThreadCount;
        const self = try allocator.create(ThreadPool);
        errdefer allocator.destroy(self);
        const threads = try allocator.alloc(std.Thread, thread_count);
        errdefer allocator.free(threads);
        self.* = .{ .allocator = allocator, .threads = threads };
        var spawned: usize = 0;
        errdefer {
            self.queue.close();
            for (threads[0..spawned]) |thread| thread.join();
        }
        for (threads) |*thread| {
            thread.* = try std.Thread.spawn(.{}, Queue.run, .{&self.queue});
            spawned += 1;
        }
        return self;
    }

    pub fn getScheduler(self: *ThreadPool) QueueScheduler {
        return .{ .queue = &self.queue };
    }
    pub fn deinit(self: *ThreadPool) void {
        self.queue.close();
        for (self.threads) |thread| thread.join();
        const allocator = self.allocator;
        allocator.free(self.threads);
        allocator.destroy(self);
    }
};
