const std = @import("std");
const io = @import("../../io/request.zig");
const Request = @This();

description: io.Description,
context: *anyopaque,
complete: *const fn (*anyopaque, io.Result) void,
/// Set by the submitter when a stop callback may call cancel(). Only such
/// requests join the reactor's active list; shutdown uses one cancel-all SQE.
cancellable: bool = false,
cancel_requested: std.atomic.Value(bool) = .init(false),
queue_next: ?*Request = null,
previous: ?*Request = null,
next: ?*Request = null,
// Reactor-owned state; never accessed by submitting or canceling threads.
cancel_sent: bool = false,
cancel_pending: bool = false,
/// The target CQE arrived while its cancellation CQE is still outstanding.
parked: bool = false,
scratch: Scratch = undefined,

/// Storage with disjoint lifetimes. The kernel copies a sleep's timespec while
/// preparing the SQE inside io_uring_enter, before any CQE for it can exist; a
/// raw CQE result is parked only after that, while waiting for the cancel CQE.
pub const Scratch = extern union {
    timeout: std.os.linux.kernel_timespec,
    res: i32,
};

pub fn finish(self: *Request, result: io.Result) void {
    const complete = self.complete;
    const context = self.context;
    complete(context, result);
}
