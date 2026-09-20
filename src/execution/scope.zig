//! Resource cleanup records, not execution reference counts. Producers must not
//! access operation storage after signaling completion. Only resource-owning
//! algorithms register here; ordinary I/O and scheduling incur no atomics.
const Mutex = @import("../detail/sync.zig").Mutex;
pub const Scope = struct {
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
    retirement_mutex: Mutex = .{},
    retirements: ?*Retirement = null,
    pub fn onRetired(self: *Scope, record: *Retirement) void {
        self.retirement_mutex.lock();
        record.next = self.retirements;
        self.retirements = record;
        self.retirement_mutex.unlock();
    }
    /// All producers have completed, so no registration can still be publishing.
    /// Detach before entering user code; continuation may destroy this scope.
    pub fn complete(self: *Scope, continuation: anytype) void {
        const records = self.retirements;
        self.retirements = null;
        releaseAfter(records, continuation);
    }
    fn releaseAfter(records: ?*Retirement, continuation: anytype) void {
        if (records) |record| {
            const next = record.next;
            const action = record.prepare(record);
            releaseAfter(next, continuation);
            action.run(); // Only stack-owned data; operation may already be gone.
        } else continuation.run();
    }
};
