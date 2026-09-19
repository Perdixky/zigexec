//! Tracks execution entries, not sender nodes. Acquire before publishing async
//! work; release after its completion handler and all operation accesses return.
const std = @import("std");
const Mutex = @import("../detail/sync.zig").Mutex;

pub const Scope = struct {
    /// An action whose context outlives the operation that registered it.
    pub const ReleaseAction = struct {
        context: ?*anyopaque = null,
        release_fn: ?*const fn (*anyopaque) void = null,
        pub fn run(self: @This()) void {
            if (self.release_fn) |function| function(self.context.?);
        }
    };
    pub const Retirement = struct {
        next: ?*Retirement = null,
        prepare: *const fn (*Retirement) ReleaseAction,
    };
    parent: ?*Scope = null,
    /// A branch may finish executing before its result stops being borrowed.
    /// Its operation storage must outlive this owner when forwarding records.
    retirement_owner: ?*Scope = null,
    retirement_mutex: Mutex = .{},
    retirements: ?*Retirement = null,
    active: std.atomic.Value(usize) = .init(0),
    context: *anyopaque = undefined,
    on_idle: *const fn (*anyopaque) void,

    /// Register while holding an execution entry. The record stays embedded in
    /// operation storage. Preparation happens before idle; release AFTER idle,
    /// so the root receiver can free its operation before association release.
    pub fn onRetired(self: *Scope, record: *Retirement) void {
        if (self.retirement_owner) |owner| return owner.onRetired(record);
        self.retirement_mutex.lock();
        record.next = self.retirements;
        self.retirements = record;
        self.retirement_mutex.unlock();
    }
    fn retire(records: ?*Retirement, context: *anyopaque, on_idle: *const fn (*anyopaque) void) void {
        if (records) |record| {
            const next = record.next;
            const action = record.prepare(record);
            // Copy actions onto this stack before idle can recycle/free records.
            retire(next, context, on_idle);
            action.run();
        } else on_idle(context);
    }

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
        if (previous == 1) {
            // No execution entry remains; no record can still be publishing.
            const records = self.retirements;
            self.retirements = null;
            retire(records, context, on_idle);
        }
        if (parent) |p| p.leave();
    }

    pub fn acquire(scope: ?*Scope) void {
        if (scope) |s| s.enter();
    }
    pub fn release(scope: ?*Scope) void {
        if (scope) |s| s.leave();
    }
};
