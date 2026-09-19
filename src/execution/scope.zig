//! Tracks execution entries, not sender nodes. Acquire before publishing async
//! work; release after its completion handler and all operation accesses return.
const std = @import("std");

pub const Scope = struct {
    parent: ?*Scope = null,
    active: std.atomic.Value(usize) = .init(0),
    context: *anyopaque = undefined,
    on_idle: *const fn (*anyopaque) void,

    pub fn enter(self: *Scope) void {
        if (self.parent) |parent| parent.enter();
        _ = self.active.fetchAdd(1, .monotonic);
    }

    /// The idle callback may recycle this scope or destroy its owner. Access no
    /// fields after decrementing: another release can invoke the callback too.
    pub fn leave(self: *Scope) void {
        const parent = self.parent;
        const context = self.context;
        const on_idle = self.on_idle;
        const previous = self.active.fetchSub(1, .acq_rel);
        std.debug.assert(previous != 0);
        if (previous == 1) on_idle(context);
        if (parent) |p| p.leave();
    }

    pub fn acquire(scope: ?*Scope) void {
        if (scope) |s| s.enter();
    }
    pub fn release(scope: ?*Scope) void {
        if (scope) |s| s.leave();
    }
};
