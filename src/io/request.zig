//! Backend-neutral POSIX I/O descriptions. All memory and handles are borrowed
//! until completion; reads/writes may be short, and zero-byte reads indicate EOF.
const std = @import("std");
pub const Handle = i32;
pub const current_offset = std.math.maxInt(u64);
pub const Kind = enum { nop, read, write, recv, send, sleep, open_at, close, fsync, accept, connect };
pub const Description = union(Kind) {
    nop,
    read: struct { fd: Handle, buffer: []u8, offset: u64 },
    write: struct { fd: Handle, buffer: []const u8, offset: u64 },
    recv: struct { fd: Handle, buffer: []u8, flags: u32 },
    send: struct { fd: Handle, buffer: []const u8, flags: u32 },
    sleep: u64, // relative monotonic nanoseconds
    open_at: struct { dir: Handle, path: [:0]const u8, flags: u32, mode: u32 },
    close: Handle,
    fsync: Handle,
    accept: struct { fd: Handle, flags: u32 },
    connect: struct { fd: Handle, address: *const std.posix.sockaddr, length: std.posix.socklen_t },
};
pub const Result = union(enum) { value: usize, err: anyerror, stopped };
pub fn Values(comptime kind: Kind) type {
    return switch (kind) {
        .read, .write, .recv, .send => @Tuple(&.{usize}),
        .open_at, .accept => @Tuple(&.{Handle}),
        else => @Tuple(&.{}),
    };
}
