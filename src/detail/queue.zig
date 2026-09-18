const sync = @import("sync.zig");
const Task = @import("task.zig").Task;
pub const Queue = struct {
    mutex: sync.Mutex = .{},
    ready: sync.Condition = .{},
    head: ?*Task = null,
    tail: ?*Task = null,
    closed: bool = false,

    pub fn submit(self: *Queue, task: *Task) error{SchedulerStopped}!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closed) return error.SchedulerStopped;
        task.next = null;
        if (self.tail) |tail| tail.next = task else self.head = task;
        self.tail = task;
        self.ready.signal();
    }
    pub fn take(self: *Queue) ?*Task {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.head == null and !self.closed) self.ready.waitForSignal(&self.mutex);
        const task = self.head orelse return null;
        self.head = task.next;
        if (self.head == null) self.tail = null;
        return task;
    }
    pub fn close(self: *Queue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.closed = true;
        self.ready.broadcast();
    }
    pub fn run(self: *Queue) void {
        while (self.take()) |task| task.run(task);
    }
};
