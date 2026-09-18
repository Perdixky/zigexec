/// Intrusive job: owned by an operation, never allocated by queue submission.
pub const Task = struct {
    next: ?*Task = null,
    run: *const fn (*Task) void,
};
