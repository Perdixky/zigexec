//! Dedicated io_uring reactor. SQ/CQ access belongs exclusively to its worker;
//! submissions and cancellation may originate from any thread. No std.Io runtime.
const std = @import("std");
const linux = std.os.linux;
const sync = @import("../../detail/sync.zig");
const submitter = @import("submission.zig");
const decode = @import("completion.zig").decode;
const schedule_sender = @import("../../io/operations/nop.zig").schedule;
const Context = @This();
threadlocal var reactor_context: ?*Context = null;
const Task = @import("../../detail/task.zig").Task;
pub const Request = @import("request.zig");
pub const Options = struct {
    entries: u16 = 64,
    /// Create the ring with SINGLE_ISSUER | DEFER_TASKRUN | COOP_TASKRUN so the
    /// kernel batches completion task work until the reactor asks for events,
    /// instead of interrupting it. Falls back to no flags if the kernel refuses.
    defer_taskrun: bool = true,
};

allocator: std.mem.Allocator,
ring: linux.IoUring,
wake_fd: linux.fd_t,
worker: std.Thread = undefined,
mutex: sync.Mutex = .{},
closing: std.atomic.Value(bool) = .init(false),
inbox_pending: std.atomic.Value(bool) = .init(false),
cancel_dirty: std.atomic.Value(bool) = .init(false),
queue_head: ?*Request = null,
queue_tail: ?*Request = null,
task_head: ?*Task = null,
task_tail: ?*Task = null,
// Fields below belong to the reactor thread. Remote inboxes are detached in
// batches; reentrant submissions append here without locking.
pending_head: ?*Request = null,
pending_tail: ?*Request = null,
local_task_head: ?*Task = null,
local_task_tail: ?*Task = null,
// Only cancellable requests are linked here, so ordinary I/O never touches
// other operations' cache lines. active_count covers every in-flight request.
active: ?*Request = null,
active_count: usize = 0,
wake_armed: bool = false,
cancel_all_sent: bool = false,

const cancel_all_data: u64 = 2; // Never a Request address: those are aligned.

pub fn init(allocator: std.mem.Allocator, options: Options) !*Context {
    if (@import("builtin").os.tag != .linux) @compileError("io_uring requires Linux");
    if (options.entries < 2 or !std.math.isPowerOfTwo(options.entries)) return error.InvalidRingSize;
    const self = try allocator.create(Context);
    errdefer allocator.destroy(self);
    const fd_result = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    if (linux.errno(fd_result) != .SUCCESS) return error.EventFdUnavailable;
    const fd: linux.fd_t = @intCast(fd_result);
    errdefer _ = linux.close(fd);
    self.* = .{ .allocator = allocator, .ring = undefined, .wake_fd = fd };
    // SINGLE_ISSUER binds the ring to its creating thread, so the reactor
    // creates it and reports setup errors back before init returns.
    var boot: Boot = .{ .options = options };
    self.worker = try std.Thread.spawn(.{}, bootAndRun, .{ self, &boot });
    if (boot.wait()) |err| {
        self.worker.join();
        return err;
    }
    return self;
}

const Boot = struct {
    options: Options,
    mutex: sync.Mutex = .{},
    finished: sync.Condition = .{},
    done: bool = false,
    err: ?anyerror = null,
    fn finish(self: *Boot, err: ?anyerror) void {
        self.mutex.lock();
        self.err = err;
        self.done = true;
        self.finished.signal();
        self.mutex.unlock();
    }
    fn wait(self: *Boot) ?anyerror {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (!self.done) self.finished.waitForSignal(&self.mutex);
        return self.err;
    }
};

fn bootAndRun(self: *Context, boot: *Boot) void {
    self.ring = setupRing(boot.options) catch |err| return boot.finish(err);
    boot.finish(null); // boot lives on the init caller's stack; never touch it again.
    self.run();
}

fn setupRing(options: Options) !linux.IoUring {
    const preferred: u32 = if (options.defer_taskrun)
        linux.IORING_SETUP_SINGLE_ISSUER | linux.IORING_SETUP_DEFER_TASKRUN | linux.IORING_SETUP_COOP_TASKRUN
    else
        0;
    var ring = linux.IoUring.init(options.entries, preferred) catch |err| switch (err) {
        error.ArgumentsInvalid => if (preferred != 0) try linux.IoUring.init(options.entries, 0) else return err,
        else => return err,
    };
    errdefer ring.deinit();
    if (ring.features & linux.IORING_FEAT_NODROP == 0) return error.SystemOutdated;
    try probeCancelAny(&ring);
    return ring;
}

/// Shutdown cancels every in-flight request with one ASYNC_CANCEL_ANY (5.19+).
/// On an empty ring, a supporting kernel answers ENOENT; older ones EINVAL.
fn probeCancelAny(ring: *linux.IoUring) !void {
    const sqe = try ring.get_sqe();
    sqe.prep_cancel(0, linux.IORING_ASYNC_CANCEL_ANY);
    _ = try ring.submit_and_wait(1);
    const cqe = try ring.copy_cqe();
    if (cqe.res == -@as(i32, @backingInt(linux.E.INVAL))) return error.SystemOutdated;
}

/// Close submissions and cancel queued/in-flight work; completion still waits
/// for target AND cancellation CQEs. Safe from any thread, including the reactor.
pub fn shutdown(self: *Context) void {
    self.mutex.lock();
    self.closing.store(true, .release);
    self.mutex.unlock();
    self.wake();
}

/// Join the worker and release the ring. Never call on the reactor thread.
/// Keep the context alive until all callers of submit/cancel/shutdown return.
pub fn deinit(self: *Context) void {
    self.shutdown();
    self.worker.join();
    self.ring.deinit();
    _ = linux.close(self.wake_fd);
    const allocator = self.allocator;
    allocator.destroy(self);
}

pub const Scheduler = struct {
    context: *Context,
    /// Allocation-free enqueue used by Env's type-erased start scheduler.
    pub fn submit(self: Scheduler, task: *Task) error{ContextClosed}!void {
        return self.context.submitTask(task);
    }
    pub fn schedule(self: Scheduler) @TypeOf(schedule_sender(self.context)) {
        return schedule_sender(self.context);
    }
};
pub fn getScheduler(self: *Context) Scheduler {
    return .{ .context = self };
}

pub fn submit(self: *Context, request: *Request) void {
    submitter.validate(request) catch |err| return request.finish(.{ .err = err });
    if (reactor_context == self) {
        if (self.closing.load(.acquire)) return request.finish(.{ .err = error.ContextClosed });
        // Fill the SQE now, while the request's cache lines are still warm from
        // connect/start; the queue drain would touch them again only after the
        // whole CQE batch. Queue instead if that could pass queued requests
        // (FIFO), if a stop is already requested (the drain reports it), or if
        // the SQ is full.
        if (self.pending_head == null and !request.cancel_requested.load(.acquire)) {
            if (self.ring.get_sqe()) |sqe| return self.issue(sqe, request) else |_| {}
        }
        request.queue_next = null;
        if (self.pending_tail) |tail| tail.queue_next = request else self.pending_head = request;
        self.pending_tail = request;
        return;
    }
    self.mutex.lock();
    if (self.closing.load(.monotonic)) {
        self.mutex.unlock();
        request.finish(.{ .err = error.ContextClosed });
        return;
    }
    request.queue_next = null;
    if (self.queue_tail) |tail| tail.queue_next = request else self.queue_head = request;
    self.queue_tail = request;
    self.inbox_pending.store(true, .release);
    self.mutex.unlock();
    self.wake();
}

fn submitTask(self: *Context, task: *Task) error{ContextClosed}!void {
    if (reactor_context == self) {
        if (self.closing.load(.acquire)) return error.ContextClosed;
        task.next = null;
        if (self.local_task_tail) |tail| tail.next = task else self.local_task_head = task;
        self.local_task_tail = task;
        return;
    }
    self.mutex.lock();
    if (self.closing.load(.monotonic)) {
        self.mutex.unlock();
        return error.ContextClosed;
    }
    task.next = null;
    if (self.task_tail) |tail| tail.next = task else self.task_head = task;
    self.task_tail = task;
    self.inbox_pending.store(true, .release);
    self.mutex.unlock();
    self.wake();
}

fn takeInbox(self: *Context) void {
    if (!self.inbox_pending.load(.acquire)) return;
    self.mutex.lock();
    const requests = self.queue_head;
    const requests_tail = self.queue_tail;
    const tasks = self.task_head;
    const tasks_tail = self.task_tail;
    self.queue_head = null;
    self.queue_tail = null;
    self.task_head = null;
    self.task_tail = null;
    self.inbox_pending.store(false, .monotonic);
    self.mutex.unlock();
    if (requests) |head| {
        if (self.pending_tail) |tail| tail.queue_next = head else self.pending_head = head;
        self.pending_tail = requests_tail;
    }
    if (tasks) |head| {
        if (self.local_task_tail) |tail| tail.next = head else self.local_task_head = head;
        self.local_task_tail = tasks_tail;
    }
}

fn runTasks(self: *Context) void {
    var next = self.local_task_head;
    self.local_task_head = null;
    self.local_task_tail = null;
    // Take one batch so reentrant submissions cannot starve kernel completions.
    while (next) |task| {
        next = task.next;
        task.run(task);
    }
}

pub fn cancel(self: *Context, request: *Request) void {
    request.cancel_requested.store(true, .release);
    // Publish AFTER the request flag. An exchange before a scan cannot lose a
    // concurrent cancellation: it either joins this scan or triggers the next.
    self.cancel_dirty.store(true, .release);
    if (reactor_context != self) self.wake();
}

fn wake(self: *Context) void {
    const one: u64 = 1;
    while (true) {
        const result = linux.write(self.wake_fd, std.mem.asBytes(&one).ptr, @sizeOf(u64));
        switch (linux.errno(result)) {
            .SUCCESS, .AGAIN => return, // An already-full counter is already a wakeup.
            .INTR => continue,
            else => @panic("zigexec: eventfd wake failed"),
        }
    }
}
fn drainWake(self: *Context) void {
    var value: u64 = undefined;
    while (true) {
        const result = linux.read(self.wake_fd, std.mem.asBytes(&value).ptr, @sizeOf(u64));
        switch (linux.errno(result)) {
            .SUCCESS => continue,
            .INTR => continue,
            .AGAIN => return,
            else => @panic("zigexec: eventfd read failed"),
        }
    }
}
fn hasQueued(self: *Context) bool {
    return self.pending_head != null or self.local_task_head != null or self.inbox_pending.load(.acquire);
}
fn pop(self: *Context) ?*Request {
    const request = self.pending_head orelse return null;
    self.pending_head = request.queue_next;
    if (self.pending_head == null) self.pending_tail = null;
    return request;
}
fn putBack(self: *Context, request: *Request) void {
    request.queue_next = self.pending_head;
    self.pending_head = request;
    if (self.pending_tail == null) self.pending_tail = request;
}

fn issue(self: *Context, sqe: *linux.io_uring_sqe, request: *Request) void {
    submitter.prepare(sqe, request);
    if (request.cancellable) {
        request.previous = null;
        request.next = self.active;
        if (self.active) |head| head.previous = request;
        self.active = request;
    }
    self.active_count += 1;
}

fn finish(self: *Context, request: *Request, result: @import("../../io/request.zig").Result) void {
    if (request.cancellable) {
        if (request.previous) |previous| previous.next = request.next else self.active = request.next;
        if (request.next) |next| next.previous = request.previous;
    }
    self.active_count -= 1;
    request.finish(result);
}

fn enter(self: *Context, wait: u32) void {
    // With DEFER_TASKRUN, completions are only posted while the owning thread
    // is inside io_uring_enter with GETEVENTS, so always enter. Otherwise keep
    // submit_and_wait's rule of skipping the syscall when there is no work.
    const result = if (self.ring.flags & linux.IORING_SETUP_DEFER_TASKRUN != 0)
        self.ring.enter(self.ring.flush_sq(), wait, linux.IORING_ENTER_GETEVENTS)
    else
        self.ring.submit_and_wait(wait);
    _ = result catch |err| switch (err) {
        error.SignalInterrupt => return,
        error.SystemResources, error.CompletionQueueOvercommitted => {
            std.Thread.yield() catch {};
            return;
        },
        // These indicate a corrupted/invalid ring, not per-operation I/O errors.
        // Do not release live kernel buffers by fabricating completions.
        else => std.debug.panic("zigexec: unrecoverable io_uring failure: {s}", .{@errorName(err)}),
    };
}

fn run(self: *Context) void {
    reactor_context = self;
    defer reactor_context = null;
    var cqes: [64]linux.io_uring_cqe = undefined;
    while (true) {
        const closing = self.closing.load(.acquire);
        // After observing shutdown, this snapshot includes every remote request
        // accepted before the shutdown admission lock closed the inbox.
        self.takeInbox();
        self.runTasks();
        // Reserve/rearm the wake poll BEFORE filling the SQ. Never block in
        // io_uring_enter without a wake poll, even if submission was partial.
        if (!self.wake_armed and !closing) {
            const sqe = self.ring.get_sqe() catch {
                self.enter(0);
                continue;
            };
            sqe.prep_poll_add(self.wake_fd, linux.POLL.IN);
            sqe.user_data = 0;
            self.wake_armed = true;
        }
        // Cancellation has priority over new submissions under queue pressure.
        var pending_cancels = false;
        if (closing and !self.cancel_all_sent and self.active_count != 0) {
            // Nothing is submitted after closing is observed, so one cancel-all
            // reaches every in-flight request, cancellable or not.
            if (self.ring.get_sqe()) |sqe| {
                sqe.prep_cancel(0, linux.IORING_ASYNC_CANCEL_ANY | linux.IORING_ASYNC_CANCEL_ALL);
                sqe.user_data = cancel_all_data;
                self.cancel_all_sent = true;
            } else |_| pending_cancels = true;
        }
        const scan_cancels = !closing and self.cancel_dirty.load(.acquire) and self.cancel_dirty.swap(false, .acquire);
        var active = if (scan_cancels) self.active else null;
        while (active) |request| : (active = request.next) {
            if (request.cancel_sent or !request.cancel_requested.load(.acquire)) continue;
            const sqe = self.ring.get_sqe() catch {
                pending_cancels = true;
                self.cancel_dirty.store(true, .release);
                break;
            };
            sqe.prep_cancel(@intFromPtr(request), 0);
            sqe.user_data = @intFromPtr(request) | 1;
            request.cancel_sent = true;
            request.cancel_pending = true;
        }
        while (true) {
            const request = self.pop() orelse break;
            if (closing or request.cancel_requested.load(.acquire)) {
                request.finish(.stopped);
                continue;
            }
            const sqe = self.ring.get_sqe() catch {
                self.putBack(request);
                break;
            };
            self.issue(sqe, request);
        }
        if (closing and self.active_count == 0 and !self.hasQueued()) break;
        // SQ capacity limits each batch, not the number of in-flight operations.
        // Flush pending batches without waiting for blocking reads to complete.
        self.enter(if (pending_cancels or self.hasQueued()) 0 else 1);
        const count = self.ring.copy_cqes(&cqes, 0) catch |err| switch (err) {
            error.SignalInterrupt, error.SystemResources, error.CompletionQueueOvercommitted => continue,
            else => std.debug.panic("zigexec: io_uring CQ failure: {s}", .{@errorName(err)}),
        };
        for (cqes[0..count], 0..) |cqe, index| {
            // Each CQE's request lives in a different, usually cold, operation.
            // Start fetching the next one while this completion runs.
            if (index + 1 < count) {
                const next_data = cqes[index + 1].user_data & ~@as(u64, 1);
                if (next_data > cancel_all_data) @prefetch(@as(*const Request, @ptrFromInt(next_data)), .{ .rw = .write });
            }
            if (cqe.user_data == 0) {
                self.wake_armed = false;
                self.drainWake();
                continue;
            }
            if (cqe.user_data == cancel_all_data) continue;
            const request: *Request = @ptrFromInt(cqe.user_data & ~@as(u64, 1));
            // Retain address identity until both CQEs arrive. This prevents a
            // late cancellation from hitting a newly allocated operation (ABA).
            if (cqe.user_data & 1 != 0) {
                request.cancel_pending = false;
                if (request.parked) self.finish(request, decode(request.description, request.scratch.res));
            } else if (request.cancel_pending) {
                request.scratch = .{ .res = cqe.res };
                request.parked = true;
            } else {
                self.finish(request, decode(request.description, cqe.res));
            }
        }
    }
}
