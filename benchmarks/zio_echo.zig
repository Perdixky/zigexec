//! Benchmark adapter: one executor, sequential recv -> complete send.
const std = @import("std");
const zio = @import("zio");

fn echo(stream: zio.net.Stream) void {
    defer stream.close();
    var buffer: [16 * 1024]u8 = undefined;
    while (true) {
        const n = stream.read(&buffer, .none) catch return;
        if (n == 0) return;
        stream.writeAll(buffer[0..n], .none) catch return;
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();
    const port = try std.fmt.parseInt(u16, args.next() orelse "0", 10);
    const runtime = try zio.Runtime.init(std.heap.page_allocator, .{ .executors = .exact(1) });
    defer runtime.deinit();
    const addr = try zio.net.IpAddress.parseIp4("127.0.0.1", port);
    const server = try addr.listen(.{ .kernel_backlog = 64 });
    defer server.close();
    std.debug.print("listening on 127.0.0.1:{d}\n", .{server.socket.address.ip.getPort()});
    var group: zio.Group = .init;
    defer group.cancel();
    while (true) {
        const stream = try server.accept(.{});
        errdefer stream.close();
        try group.spawn(echo, .{stream});
    }
}
