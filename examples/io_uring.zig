const std = @import("std");
const ex = @import("zigexec");
const linux = std.os.linux;
const Io = ex.io.For(*ex.IoUring);

const ReadBack = struct {
    context: *ex.IoUring,
    file: i32,
    buffer: []u8,
    pub fn call(self: @This(), written: usize) Io.ReadSome {
        return Io.readSome(self.context, self.file, self.buffer[0..written], 0);
    }
};

pub fn main() !void {
    const context = try ex.IoUring.init(std.heap.page_allocator, .{});
    defer context.deinit();
    // Anonymous file; no files are created on the user's filesystem.
    const result = linux.memfd_create("zigexec-example", linux.MFD.CLOEXEC);
    if (linux.errno(result) != .SUCCESS) return error.CannotCreateFile;
    const file: i32 = @intCast(result);
    defer _ = linux.close(file);
    var buffer: [64]u8 = undefined;
    const work = Io.writeSome(context, file, "hello io_uring", 0)
        .letValue(ex.upstream().letValue(ReadBack, .{ context, file, &buffer }), .{});
    const n = (try work.syncWait(.{ .allocator = std.heap.page_allocator })).?[0];
    std.debug.print("read {d} bytes: {s}\n", .{ n, buffer[0..n] });
}
