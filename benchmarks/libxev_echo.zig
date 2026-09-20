//! Benchmark adapter: one io_uring loop, sequential recv -> complete send.
const std = @import("std");
const xev = @import("xev").IO_Uring;
const linux = std.os.linux;
const allocator = std.heap.page_allocator;

const Client = struct {
    completion: xev.Completion = undefined,
    buffer: [16 * 1024]u8 = undefined,

    fn close(self: *Client, loop: *xev.Loop, c: *xev.Completion, socket: xev.TCP) xev.CallbackAction {
        socket.close(loop, c, Client, self, closed);
        return .disarm;
    }
    fn closed(ud: ?*Client, _: *xev.Loop, _: *xev.Completion, _: xev.TCP, result: xev.CloseError!void) xev.CallbackAction {
        result catch @panic("close failed");
        allocator.destroy(ud.?);
        return .disarm;
    }
    fn read(ud: ?*Client, loop: *xev.Loop, c: *xev.Completion, socket: xev.TCP, _: xev.ReadBuffer, result: xev.ReadError!usize) xev.CallbackAction {
        const self = ud.?;
        const n = result catch return self.close(loop, c, socket);
        if (n == 0) return self.close(loop, c, socket);
        socket.write(loop, c, .{ .slice = self.buffer[0..n] }, Client, self, written);
        return .disarm;
    }
    fn written(ud: ?*Client, loop: *xev.Loop, c: *xev.Completion, socket: xev.TCP, buffer: xev.WriteBuffer, result: xev.WriteError!usize) xev.CallbackAction {
        const self = ud.?;
        const n = result catch return self.close(loop, c, socket);
        if (n == 0) return self.close(loop, c, socket);
        if (n < buffer.slice.len) {
            socket.write(loop, c, .{ .slice = buffer.slice[n..] }, Client, self, written);
        } else {
            socket.read(loop, c, .{ .slice = &self.buffer }, Client, self, read);
        }
        return .disarm;
    }
};

fn accepted(_: ?*void, loop: *xev.Loop, _: *xev.Completion, result: xev.AcceptError!xev.TCP) xev.CallbackAction {
    const socket = result catch @panic("accept failed");
    const client = allocator.create(Client) catch @panic("out of memory");
    socket.read(loop, &client.completion, .{ .slice = &client.buffer }, Client, client, Client.read);
    return .rearm;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();
    const port = try std.fmt.parseInt(u16, args.next() orelse "0", 10);
    var loop = try xev.Loop.init(.{ .entries = 64 });
    defer loop.deinit();
    const socket = try xev.TCP.init(try std.Io.net.IpAddress.parse("127.0.0.1", port));
    defer _ = linux.close(socket.fd);
    try socket.bind(try std.Io.net.IpAddress.parse("127.0.0.1", port));
    try socket.listen(64);
    var addr: linux.sockaddr.in = undefined;
    var len: linux.socklen_t = @sizeOf(@TypeOf(addr));
    if (linux.errno(linux.getsockname(socket.fd, @ptrCast(&addr), &len)) != .SUCCESS) return error.GetSockName;
    var completion: xev.Completion = undefined;
    socket.accept(&loop, &completion, void, null, accepted);
    std.debug.print("listening on 127.0.0.1:{d}\n", .{std.mem.bigToNative(u16, addr.port)});
    try loop.run(.until_done);
}
