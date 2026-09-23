//! Work-stealing pool. Each worker owns a bounded FIFO ring: tasks submitted
//! from a worker go to its own ring without locking, and idle workers steal
//! half of a victim's ring. Submissions from other threads (and ring overflow)
//! use one mutex-protected injection queue.
//!
//! Wakeups follow a searching/sleeping protocol: a push only wakes a sleeper
//! when no worker is already searching, and the last searcher to find work
//! wakes another if more remains. All counters and queue publications that
//! take part in that handshake are seq_cst, so either the pusher sees a
//! sleeper or the sleeper's final re-check sees the task.
const std = @import("std");
const sync = @import("../detail/sync.zig");
const Task = @import("../detail/task.zig").Task;
const Scheduled = @import("../detail/scheduled.zig").Scheduled;
const fluent = @import("../execution/sender.zig");

threadlocal var current_worker: ?*Worker = null;

const capacity = 256; // Power of two: indices wrap with u32 arithmetic.
const spin_rounds = 64; // Search rounds before parking; each round scans every queue.
const global_interval = 61; // Check the injection queue first this often, for fairness.

const Worker = struct {
    pool: *ThreadPool,
    // Owner pushes at tail; the owner and thieves take at head via CAS.
    head: std.atomic.Value(u32) align(std.atomic.cache_line) = .init(0),
    tail: std.atomic.Value(u32) = .init(0),
    slots: [capacity]std.atomic.Value(?*Task) = @splat(.init(null)),
    ticks: u32 = 0,
    random: u32,

    /// Owner only. Returns false when the ring is full.
    fn push(self: *Worker, task: *Task) bool {
        const head = self.head.load(.acquire);
        const tail = self.tail.load(.monotonic);
        if (tail -% head >= capacity) return false;
        self.slots[tail % capacity].store(task, .monotonic);
        self.tail.store(tail +% 1, .seq_cst);
        return true;
    }

    /// Owner only.
    fn pop(self: *Worker) ?*Task {
        while (true) {
            const head = self.head.load(.acquire);
            if (head == self.tail.load(.monotonic)) return null;
            const task = self.slots[head % capacity].load(.monotonic);
            if (self.head.cmpxchgWeak(head, head +% 1, .acq_rel, .monotonic) == null) return task;
        }
    }

    fn isEmpty(self: *Worker) bool {
        return self.tail.load(.seq_cst) == self.head.load(.seq_cst);
    }

    /// Called by the owner of `self`, whose ring is empty. Moves half of the
    /// victim's tasks into this ring and returns one of them to run.
    fn stealFrom(self: *Worker, victim: *Worker) ?*Task {
        while (true) {
            const head = victim.head.load(.acquire);
            const tail = victim.tail.load(.acquire);
            const available = tail -% head;
            if (available == 0) return null;
            if (available > capacity) continue; // Torn snapshot; reload.
            const count = available - available / 2;
            // Slots past our tail are private until published, so a failed CAS
            // merely discards these copies.
            const own_tail = self.tail.load(.monotonic);
            for (0..count - 1) |i| {
                const task = victim.slots[(head +% @as(u32, @intCast(i))) % capacity].load(.monotonic);
                self.slots[(own_tail +% @as(u32, @intCast(i))) % capacity].store(task, .monotonic);
            }
            const task = victim.slots[(head +% count -% 1) % capacity].load(.monotonic);
            if (victim.head.cmpxchgWeak(head, head +% count, .acq_rel, .monotonic) != null) continue;
            if (count > 1) self.tail.store(own_tail +% (count - 1), .seq_cst);
            return task;
        }
    }

    fn stealAny(self: *Worker) ?*Task {
        const workers = self.pool.workers;
        self.random ^= self.random << 13;
        self.random ^= self.random >> 17;
        self.random ^= self.random << 5;
        const start = self.random % workers.len;
        for (0..workers.len) |offset| {
            const victim = &workers[(start + offset) % workers.len];
            if (victim == self) continue;
            if (self.stealFrom(victim)) |task| return task;
        }
        return null;
    }

    fn run(self: *Worker) void {
        current_worker = self;
        defer current_worker = null;
        const pool = self.pool;
        while (true) {
            if (self.next()) |task| {
                task.run(task);
                continue;
            }
            _ = pool.searching.fetchAdd(1, .seq_cst);
            const task = self.search() orelse return;
            pool.foundWork();
            task.run(task);
        }
    }

    fn next(self: *Worker) ?*Task {
        self.ticks +%= 1;
        if (self.ticks % global_interval == 0) {
            if (self.pool.popGlobal()) |task| return task;
        }
        return self.pop() orelse self.pool.popGlobal();
    }

    /// Counted as searching on entry. Returns null once the pool is closed and
    /// no work remains; searching has then already been released.
    fn search(self: *Worker) ?*Task {
        const pool = self.pool;
        while (true) {
            for (0..spin_rounds) |_| {
                if (pool.popGlobal()) |task| return task;
                if (self.stealAny()) |task| return task;
                std.atomic.spinLoopHint();
            }
            if (!pool.park()) return null;
        }
    }
};

pub const ThreadPool = struct {
    pub const Scheduler = struct {
        pool: *ThreadPool,
        pub fn schedule(self: Scheduler) fluent.Sender(Scheduled(Scheduler)) {
            return fluent.asSender(Scheduled(Scheduler){ .scheduler = self });
        }
        pub fn submit(self: Scheduler, task: *Task) error{SchedulerStopped}!void {
            return self.pool.submit(task);
        }
    };

    allocator: std.mem.Allocator,
    threads: []std.Thread,
    workers: []align(std.atomic.cache_line) Worker,
    // Injection queue; closed is written under mutex so no submission is lost.
    mutex: sync.Mutex = .{},
    global_head: ?*Task = null,
    global_tail: ?*Task = null,
    global_pending: std.atomic.Value(bool) align(std.atomic.cache_line) = .init(false),
    closed: std.atomic.Value(bool) = .init(false),
    // Idle coordination; read on every push, written only on state changes.
    searching: std.atomic.Value(u32) align(std.atomic.cache_line) = .init(0),
    sleepers: std.atomic.Value(u32) = .init(0),
    epoch: std.atomic.Value(u32) = .init(0),

    /// A fixed-size pool, allocated once at a stable address. Complete
    /// operations before deinit. Never deinit from one of this pool's workers.
    pub fn init(allocator: std.mem.Allocator, thread_count: usize) !*ThreadPool {
        if (thread_count == 0) return error.InvalidThreadCount;
        const self = try allocator.create(ThreadPool);
        errdefer allocator.destroy(self);
        const threads = try allocator.alloc(std.Thread, thread_count);
        errdefer allocator.free(threads);
        const workers = try allocator.alignedAlloc(Worker, .fromByteUnits(std.atomic.cache_line), thread_count);
        errdefer allocator.free(workers);
        self.* = .{ .allocator = allocator, .threads = threads, .workers = workers };
        for (workers, 0..) |*worker, i| worker.* = .{ .pool = self, .random = @as(u32, @intCast(i)) *% 0x9E3779B9 | 1 };
        var spawned: usize = 0;
        errdefer {
            self.close();
            for (threads[0..spawned]) |thread| thread.join();
        }
        for (threads, workers) |*thread, *worker| {
            thread.* = try std.Thread.spawn(.{}, Worker.run, .{worker});
            spawned += 1;
        }
        return self;
    }

    pub fn getScheduler(self: *ThreadPool) Scheduler {
        return .{ .pool = self };
    }

    /// Close submissions, run every accepted task, then join the workers.
    pub fn deinit(self: *ThreadPool) void {
        self.close();
        for (self.threads) |thread| thread.join();
        const allocator = self.allocator;
        allocator.free(self.workers);
        allocator.free(self.threads);
        allocator.destroy(self);
    }

    /// Reject further submissions; accepted tasks still run. Idempotent.
    pub fn close(self: *ThreadPool) void {
        self.mutex.lock();
        self.closed.store(true, .seq_cst);
        self.mutex.unlock();
        _ = self.epoch.fetchAdd(1, .release);
        sync.wake(&self.epoch, std.math.maxInt(i32));
    }

    fn submit(self: *ThreadPool, task: *Task) error{SchedulerStopped}!void {
        if (current_worker) |worker| {
            if (worker.pool == self) {
                // Accepted work always runs: this worker drains its own ring
                // before it can observe closed and exit.
                if (self.closed.load(.acquire)) return error.SchedulerStopped;
                if (!worker.push(task)) self.appendGlobal(task);
                self.notify();
                return;
            }
        }
        self.mutex.lock();
        if (self.closed.load(.monotonic)) {
            self.mutex.unlock();
            return error.SchedulerStopped;
        }
        self.appendGlobalLocked(task);
        self.mutex.unlock();
        self.notify();
    }

    fn appendGlobal(self: *ThreadPool, task: *Task) void {
        self.mutex.lock();
        self.appendGlobalLocked(task);
        self.mutex.unlock();
    }

    fn appendGlobalLocked(self: *ThreadPool, task: *Task) void {
        task.next = null;
        if (self.global_tail) |tail| tail.next = task else self.global_head = task;
        self.global_tail = task;
        self.global_pending.store(true, .seq_cst);
    }

    fn popGlobal(self: *ThreadPool) ?*Task {
        if (!self.global_pending.load(.seq_cst)) return null;
        self.mutex.lock();
        defer self.mutex.unlock();
        const task = self.global_head orelse return null;
        self.global_head = task.next;
        if (self.global_head == null) {
            self.global_tail = null;
            self.global_pending.store(false, .seq_cst);
        }
        return task;
    }

    fn hasWork(self: *ThreadPool) bool {
        if (self.global_pending.load(.seq_cst)) return true;
        for (self.workers) |*worker| if (!worker.isEmpty()) return true;
        return false;
    }

    /// After publishing a task. A searching worker is guaranteed to observe it:
    /// it re-checks every queue after leaving the searching state.
    fn notify(self: *ThreadPool) void {
        if (self.searching.load(.seq_cst) != 0) return;
        if (self.sleepers.load(.seq_cst) == 0) return;
        self.wakeOne();
    }

    fn wakeOne(self: *ThreadPool) void {
        _ = self.epoch.fetchAdd(1, .release);
        sync.wake(&self.epoch, 1);
    }

    /// A searcher found a task. Pushers skipped wakeups while it searched, so
    /// the last searcher hands the search on if more work is visible.
    fn foundWork(self: *ThreadPool) void {
        if (self.searching.fetchSub(1, .seq_cst) != 1) return;
        if (self.sleepers.load(.seq_cst) != 0 and self.hasWork()) self.wakeOne();
    }

    /// Called while counted as searching. Returns true to keep searching, or
    /// false once closed and drained (searching released, not sleeping).
    fn park(self: *ThreadPool) bool {
        const epoch = self.epoch.load(.acquire);
        _ = self.sleepers.fetchAdd(1, .seq_cst);
        _ = self.searching.fetchSub(1, .seq_cst);
        // Read closed BEFORE checking for work: every accepted submission is
        // published before closed is set, so seeing closed implies seeing it.
        const closed = self.closed.load(.seq_cst);
        if (self.hasWork()) {
            _ = self.sleepers.fetchSub(1, .seq_cst);
            _ = self.searching.fetchAdd(1, .seq_cst);
            return true;
        }
        if (closed) {
            _ = self.sleepers.fetchSub(1, .seq_cst);
            return false;
        }
        sync.wait(&self.epoch, epoch);
        _ = self.sleepers.fetchSub(1, .seq_cst);
        _ = self.searching.fetchAdd(1, .seq_cst);
        return true;
    }
};
