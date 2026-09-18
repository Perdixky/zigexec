const std = @import("std");
const linux = std.os.linux;
const Request = @import("request.zig");

pub fn validate(request: *const Request) !void {
    const length = switch (request.description) {
        .read => |args| args.buffer.len,
        .write => |args| args.buffer.len,
        .recv => |args| args.buffer.len,
        .send => |args| args.buffer.len,
        else => 0,
    };
    if (length > std.math.maxInt(u32)) return error.InvalidBufferLength;
}

pub fn prepare(sqe: *linux.io_uring_sqe, request: *Request) void {
    switch (request.description) {
        .nop => sqe.prep_nop(),
        .read => |args| sqe.prep_read(args.fd, args.buffer, args.offset),
        .write => |args| sqe.prep_write(args.fd, args.buffer, args.offset),
        .recv => |args| sqe.prep_recv(args.fd, args.buffer, args.flags),
        // MSG_NOSIGNAL makes broken peers report errors without killing the process.
        .send => |args| sqe.prep_send(args.fd, args.buffer, args.flags | linux.MSG.NOSIGNAL),
        .open_at => |args| sqe.prep_openat(args.dir, args.path.ptr, @bitCast(args.flags), args.mode),
        .close => |fd| sqe.prep_close(fd),
        .fsync => |fd| sqe.prep_fsync(fd, 0),
        .accept => |args| sqe.prep_accept(args.fd, null, null, args.flags),
        .connect => |args| sqe.prep_connect(args.fd, args.address, args.length),
        .sleep => |ns| {
            request.timeout = .{ .sec = @intCast(ns / std.time.ns_per_s), .nsec = @intCast(ns % std.time.ns_per_s) };
            sqe.prep_timeout(&request.timeout, 0, 0);
        },
    }
    // Low bit is reserved for the cancellation CQE referring to the same request.
    std.debug.assert(@intFromPtr(request) & 1 == 0);
    sqe.user_data = @intFromPtr(request);
}
