//! Linux TCP echo server using zigexec + io_uring, without std.Io or libc.
//! Run: zig build run-echo -- [port] [--once]
//! Connections are served sequentially; the reactor drives each read/write loop.
const std = @import("std");
const ex = @import("zigexec");
const linux = std.os.linux;
const Io = ex.io.For(*ex.IoUring);

// One live connection at a time. This state outlives the complete server task.
// The graph owns when resources are acquired and released; callbacks capture
// only this pointer, and all socket I/O is performed by senders.
const Connection = struct {
    context: *ex.IoUring,
    allocator: std.mem.Allocator = undefined,
    socket: ?i32 = null,
    buffer: ?[]u8 = null,

    fn close(self: *@This()) void {
        if (self.buffer) |buffer| self.allocator.free(buffer);
        self.buffer = null;
        if (self.socket) |socket| _ = linux.close(socket);
        self.socket = null;
    }
};
const SetAllocator = struct {
    connection: *Connection,
    pub fn call(self: @This(), allocator: std.mem.Allocator) void {
        self.connection.allocator = allocator;
    }
};
const Accept = struct {
    context: *ex.IoUring,
    listener: i32,
    pub fn call(self: @This()) Io.Accept {
        return Io.accept(self.context, self.listener, linux.SOCK.CLOEXEC);
    }
};
const OpenConnection = struct {
    connection: *Connection,
    pub fn call(self: @This(), socket: i32) !void {
        // Record the accepted fd before allocating, so failure closes it too.
        self.connection.socket = socket;
        self.connection.buffer = try self.connection.allocator.alloc(u8, 16 * 1024);
    }
};
const Receive = struct {
    connection: *Connection,
    pub fn call(self: @This()) Io.Recv {
        const c = self.connection;
        return Io.recv(c.context, c.socket.?, c.buffer.?, 0);
    }
};
const EchoChunk = struct {
    connection: *Connection,
    pub fn call(self: @This(), received: usize) error{EndOfStream}!Io.SendAll {
        if (received == 0) return error.EndOfStream;
        const c = self.connection;
        // Short writes are retried by sendAll; a broken peer must not SIGPIPE.
        return Io.sendAll(c.context, c.socket.?, c.buffer.?[0..received], linux.MSG.NOSIGNAL);
    }
};
const DiscardCount = struct {
    pub fn call(_: @This(), _: usize) void {}
};
const FinishConnection = struct {
    connection: *Connection,
    pub fn call(self: @This(), err: anyerror) anyerror!void {
        self.connection.close();
        if (err == error.OutOfMemory) return err;
        if (err != error.EndOfStream) std.debug.print("connection: {s}\n", .{@errorName(err)});
        // EOF and peer I/O errors end this connection; accept the next one.
    }
};
const FinishStopped = struct {
    connection: *Connection,
    pub fn call(self: @This()) ex.JustStopped(.{}) {
        self.connection.close();
        return ex.justStopped(ex.Values(.{}));
    }
};
const ShouldStop = struct {
    once: bool,
    pub fn call(self: @This()) bool {
        return self.once;
    }
};

fn checked(comptime name: []const u8, result: usize) !usize {
    const err = linux.errno(result);
    if (err != .SUCCESS) {
        std.debug.print("{s}: {s}\n", .{ name, @tagName(err) });
        return error.SocketSetupFailed;
    }
    return result;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();
    const port_text = args.next() orelse "9000";
    if (std.mem.eql(u8, port_text, "--help")) {
        std.debug.print("usage: zigexec-tcp-echo [port] [--once]\n", .{});
        return;
    }
    const port = try std.fmt.parseInt(u16, port_text, 10);
    const once = if (args.next()) |arg| blk: {
        if (!std.mem.eql(u8, arg, "--once")) return error.InvalidArgument;
        break :blk true;
    } else false;
    if (args.next() != null) return error.InvalidArgument;

    const allocator = std.heap.page_allocator;
    const context = try ex.IoUring.init(allocator, .{});
    defer context.deinit();
    const listener: i32 = @intCast(try checked("socket", linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0)));
    defer _ = linux.close(listener);
    const reuse: i32 = 1;
    _ = try checked("setsockopt", linux.setsockopt(listener, linux.SOL.SOCKET, linux.SO.REUSEADDR, std.mem.asBytes(&reuse).ptr, @sizeOf(i32)));
    var address: linux.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
    };
    _ = try checked("bind", linux.bind(listener, @ptrCast(&address), @sizeOf(@TypeOf(address))));
    _ = try checked("listen", linux.listen(listener, 64));
    var address_length: linux.socklen_t = @sizeOf(@TypeOf(address));
    _ = try checked("getsockname", linux.getsockname(listener, @ptrCast(&address), &address_length));
    std.debug.print("listening on 127.0.0.1:{d}\n", .{std.mem.bigToNative(u16, address.port)});

    var connection: Connection = .{ .context = context };
    defer connection.close();

    const server = ex.readAllocator()
        .then(SetAllocator, .{&connection})
        .letValue(
        ex.upstream()
            .letValue(Accept, .{ context, listener })
            .letValue(
                ex.upstream()
                    .then(OpenConnection, .{&connection})
                    .letValue(
                        ex.upstream()
                            .letValue(Receive, .{&connection})
                            .letValue(EchoChunk, .{&connection})
                            .then(DiscardCount, .{})
                            .repeatEffect(),
                        .{},
                    )
                    .uponError(FinishConnection, .{&connection})
                    .letStopped(FinishStopped, .{&connection})
                    .then(ShouldStop, .{once}),
                .{},
            )
            .repeatEffectUntil(),
        .{},
    );

    // The only wait: accept, read, write, cleanup, and repetition form one graph.
    _ = try server.syncWait(.{ .allocator = allocator });
}
