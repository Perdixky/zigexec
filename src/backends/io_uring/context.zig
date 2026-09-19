//! Dedicated io_uring reactor. SQ/CQ access belongs exclusively to its worker;
//! submissions and cancellation may originate from any thread. No std.Io runtime.
const std = @import("std");
const linux = std.os.linux;
const sync = @import("../../detail/sync.zig");
const submitter = @import("submission.zig");
const decode = @import("completion.zig").decode;
const schedule_sender = @import("../../io/operations/nop.zig").schedule;
const Context = @This();
const Task = @import("../../detail/task.zig").Task;
pub const Request = @import("request.zig");
pub const Options = struct { entries: u16 = 64 };

allocator: std.mem.Allocator,
ring: linux.IoUring,
wake_fd: linux.fd_t,
worker: std.Thread = undefined,
mutex: sync.Mutex = .{},
closing: bool = false,
queue_head: ?*Request = null,
queue_tail: ?*Request = null,
task_head: ?*Task = null,
task_tail: ?*Task = null,
// Fields below belong to the reactor thread.
active: ?*Request = null,
active_count: usize = 0,
wake_armed: bool = false,

pub fn init(allocator: std.mem.Allocator, options: Options) !*Context {
    if (@import("builtin").os.tag != .linux) @compileError("io_uring requires Linux");
    if (options.entries < 2 or !std.math.isPowerOfTwo(options.entries)) return error.InvalidRingSize;
    const self = try allocator.create(Context);
    errdefer allocator.destroy(self);
    var ring = try linux.IoUring.init(options.entries, 0);
    errdefer ring.deinit();
    if (ring.features & linux.IORING_FEAT_NODROP == 0) return error.SystemOutdated;
    const fd_result = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    if (linux.errno(fd_result) != .SUCCESS) return error.EventFdUnavailable;
    const fd: linux.fd_t = @intCast(fd_result);
    errdefer _ = linux.close(fd);
    self.* = .{ .allocator = allocator, .ring = ring, .wake_fd = fd };
    self.worker = try std.Thread.spawn(.{}, run, .{self});
    return self;
}

/// Close submissions and cancel queued/in-flight work; completion still waits
/// for target AND cancellation CQEs. Safe from any thread, including the reactor.
pub fn shutdown(self: *Context) void {
    self.mutex.lock();
    self.closing = true;
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
    self.mutex.lock();
    if (self.closing) {
        self.mutex.unlock();
        request.finish(.{ .err = error.ContextClosed });
        return;
    }
    request.queue_next = null;
    if (self.queue_tail) |tail| tail.queue_next = request else self.queue_head = request;
    self.queue_tail = request;
    self.mutex.unlock();
    self.wake();
}

fn submitTask(self: *Context, task: *Task) error{ContextClosed}!void {
    self.mutex.lock();
    if (self.closing) {
        self.mutex.unlock();
        return error.ContextClosed;
    }
    task.next = null;
    if (self.task_tail) |tail| tail.next = task else self.task_head = task;
    self.task_tail = task;
    self.mutex.unlock();
    self.wake();
}
fn runTasks(self: *Context) void {
    self.mutex.lock();
    var next = self.task_head;
    self.task_head = null;
    self.task_tail = null;
    self.mutex.unlock();
    // Take one batch so reentrant submissions cannot starve kernel completions.
    while (next) |task| {
        next = task.next;
        task.run(task);
    }
}

pub fn cancel(self: *Context, request: *Request) void {
    request.cancel_requested.store(true, .release);
    self.wake();
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
fn isClosing(self: *Context) bool {
    self.mutex.lock();
    defer self.mutex.unlock();
    return self.closing;
}
fn hasQueued(self: *Context) bool {
    self.mutex.lock();
    defer self.mutex.unlock();
    return self.queue_head != null;
}
fn pop(self: *Context) ?*Request {
    self.mutex.lock();
    defer self.mutex.unlock();
    const request = self.queue_head orelse return null;
    self.queue_head = request.queue_next;
    if (self.queue_head == null) self.queue_tail = null;
    return request;
}
fn putBack(self: *Context, request: *Request) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    request.queue_next = self.queue_head;
    self.queue_head = request;
    if (self.queue_tail == null) self.queue_tail = request;
}

fn finish(self: *Context, request: *Request) void {
    if (request.previous) |previous| previous.next = request.next else self.active = request.next;
    if (request.next) |next| next.previous = request.previous;
    self.active_count -= 1;
    request.finish(request.result.?);
}

fn enter(self: *Context, wait: u32) void {
    _ = self.ring.submit_and_wait(wait) catch |err| switch (err) {
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
    var cqes: [64]linux.io_uring_cqe = undefined;
    while (true) {
        self.runTasks();
        const closing = self.isClosing();
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
        var active = self.active;
        while (active) |request| : (active = request.next) {
            if (request.result != null or request.cancel_sent) continue;
            if (!closing and !request.cancel_requested.load(.acquire)) continue;
            const sqe = self.ring.get_sqe() catch {
                pending_cancels = true;
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
            submitter.prepare(sqe, request);
            request.previous = null;
            request.next = self.active;
            if (self.active) |head| head.previous = request;
            self.active = request;
            self.active_count += 1;
        }
        if (closing and self.active_count == 0) {
            // A submission may have raced the batch snapshot before shutdown.
            self.runTasks();
            break;
        }
        // SQ capacity limits each batch, not the number of in-flight operations.
        // Flush pending batches without waiting for blocking reads to complete.
        self.enter(if (pending_cancels or self.hasQueued()) 0 else 1);
        const count = self.ring.copy_cqes(&cqes, 0) catch |err| switch (err) {
            error.SignalInterrupt, error.SystemResources, error.CompletionQueueOvercommitted => continue,
            else => std.debug.panic("zigexec: io_uring CQ failure: {s}", .{@errorName(err)}),
        };
        for (cqes[0..count]) |cqe| {
            if (cqe.user_data == 0) {
                self.wake_armed = false;
                self.drainWake();
                continue;
            }
            const request: *Request = @ptrFromInt(cqe.user_data & ~@as(u64, 1));
            if (cqe.user_data & 1 != 0) {
                request.cancel_pending = false;
            } else {
                request.result = decode(request.description, cqe.res);
            }
            // Retain address identity until both CQEs arrive. This prevents a
            // late cancellation from hitting a newly allocated operation (ABA).
            if (request.result != null and !request.cancel_pending) self.finish(request);
        }
    }
}
