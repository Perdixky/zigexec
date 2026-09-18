const std = @import("std");
const io = @import("../../io/request.zig");
const Request = @This();

description: io.Description,
context: *anyopaque,
complete: *const fn (*anyopaque, io.Result) void,
cancel_requested: std.atomic.Value(bool) = .init(false),
queue_next: ?*Request = null,
previous: ?*Request = null,
next: ?*Request = null,
// Reactor-owned state; never accessed by submitting or canceling threads.
cancel_sent: bool = false,
cancel_pending: bool = false,
result: ?io.Result = null,
timeout: std.os.linux.kernel_timespec = undefined,

pub fn finish(self: *Request, result: io.Result) void {
    const complete = self.complete;
    const context = self.context;
    complete(context, result);
}
