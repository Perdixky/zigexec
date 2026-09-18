//! Intrusive, allocation-free stop source. Keep its address stable after use.
const std = @import("std");
const sync = @import("../detail/sync.zig");
const Callback = @import("callback.zig");
const Token = @import("token.zig");
const Source = @This();

requested: std.atomic.Value(bool) = .init(false),
mutex: sync.Mutex = .{},
finished: sync.Condition = .{},
head: ?*Callback = null,
running: usize = 0,
registrations: usize = 0,

pub fn token(self: *Source) Token {
    return .{ .source = self };
}

/// The winning caller runs registered callbacks synchronously, outside the lock.
/// Recursive requests return false. Callbacks may register/remove callbacks.
/// Source lifetime must include the whole call, even if a callback completes work.
pub fn requestStop(self: *Source) bool {
    self.mutex.lock();
    if (self.requested.swap(true, .acq_rel)) {
        self.mutex.unlock();
        return false;
    }
    while (self.head) |callback| {
        self.unlinkLocked(callback);
        self.invokeLocked(callback);
    }
    self.mutex.unlock();
    return true;
}

/// Check that all registrations and dispatches have ended before destroying a source.
pub fn deinit(self: *Source) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    std.debug.assert(self.head == null and self.running == 0 and self.registrations == 0);
}

// Internal registration protocol; callers hold mutex.
pub fn unlinkLocked(self: *Source, callback: *Callback) void {
    if (callback.previous) |previous| previous.next = callback.next else self.head = callback.next;
    if (callback.next) |next| next.previous = callback.previous;
    callback.linked = false;
}

pub fn invokeLocked(self: *Source, callback: *Callback) void {
    // Execution bookkeeping lives on the dispatcher's stack, so a callback may
    // unregister AND destroy its own registration while executing.
    var invocation: Callback.Invocation = .{ .thread = std.Thread.getCurrentId() };
    callback.invocation = &invocation;
    const function = callback.function;
    const context = callback.context;
    self.running += 1;
    self.mutex.unlock();
    function(context);
    self.mutex.lock();
    if (!invocation.removed) callback.invocation = null;
    self.running -= 1;
    self.finished.broadcast();
}
