//! Internal platform synchronization. Independent of std.Io and libc.
//! Linux backend: private futexes. The sender protocol is platform-neutral.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

pub fn wait(word: *const std.atomic.Value(u32), expected: u32) void {
    if (builtin.os.tag != .linux) @compileError("zigexec blocking backend currently requires Linux");
    const result = linux.futex_4arg(&word.raw, .{ .cmd = .WAIT, .private = true }, expected, null);
    switch (linux.errno(result)) {
        .SUCCESS, .INTR, .AGAIN => {},
        else => @panic("zigexec: unexpected futex wait failure"),
    }
}

pub fn wake(word: *const std.atomic.Value(u32), count: u32) void {
    if (builtin.os.tag != .linux) @compileError("zigexec blocking backend currently requires Linux");
    const result = linux.futex_3arg(&word.raw, .{ .cmd = .WAKE, .private = true }, count);
    if (linux.errno(result) != .SUCCESS) @panic("zigexec: unexpected futex wake failure");
}

pub const Mutex = struct {
    // 0 = unlocked, 1 = locked, 2 = contended.
    state: std.atomic.Value(u32) = .init(0),

    pub fn lock(self: *Mutex) void {
        if (self.state.cmpxchgStrong(0, 1, .acquire, .monotonic) == null) return;
        while (self.state.swap(2, .acquire) != 0) wait(&self.state, 2);
    }

    pub fn unlock(self: *Mutex) void {
        const previous = self.state.swap(0, .release);
        std.debug.assert(previous != 0);
        if (previous == 2) wake(&self.state, 1);
    }
};

pub const Condition = struct {
    epoch: std.atomic.Value(u32) = .init(0),
    // Protected by the associated mutex. Lets signal/broadcast skip the futex
    // syscall entirely in the common case where nobody is blocked.
    waiters: u32 = 0,

    /// Caller must hold mutex and check its predicate in a loop. Signals must
    /// be sent under the same mutex, before unlocking it.
    pub fn waitForSignal(self: *Condition, mutex: *Mutex) void {
        const epoch = self.epoch.load(.monotonic);
        self.waiters += 1;
        mutex.unlock();
        wait(&self.epoch, epoch);
        mutex.lock();
        self.waiters -= 1;
    }

    pub fn signal(self: *Condition) void {
        if (self.waiters == 0) return;
        _ = self.epoch.fetchAdd(1, .release);
        wake(&self.epoch, 1);
    }

    pub fn broadcast(self: *Condition) void {
        if (self.waiters == 0) return;
        _ = self.epoch.fetchAdd(1, .release);
        wake(&self.epoch, std.math.maxInt(i32));
    }
};
