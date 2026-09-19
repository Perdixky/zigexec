//! Linux TCP echo server using zigexec + io_uring, without std.Io or libc.
//! Run: zig build run-echo -- [port] [--once]
//! One accept loop spawns independent echo tasks on one io_uring scheduler.
const std = @import("std");
const ex = @import("zigexec");
const linux = std.os.linux;
const Io = ex.io.For(*ex.IoUring);

// The factory lives inside the spawned operation. Its buffer stays at a stable
// address until that task's setFinished; no buffer points into the accept loop.
const Echo = struct {
    context: *ex.IoUring,
    socket: i32,
    buffer: [16 * 1024]u8 = undefined,

    const Loop = Io.Recv.LetValue(EchoChunk).Then(DiscardCount).RepeatEffect().UponError(PeerError);
    pub fn call(self: *@This()) Loop {
        return Io.recv(self.context, self.socket, &self.buffer, 0)
            .letValue(EchoChunk, .{self})
            .then(DiscardCount, .{})
            .repeatEffect()
            .uponError(PeerError, .{});
    }
};
const EchoChunk = struct {
    connection: *Echo,
    pub fn call(self: @This(), received: usize) error{EndOfStream}!Io.SendAll {
        if (received == 0) return error.EndOfStream;
        const c = self.connection;
        return Io.sendAll(c.context, c.socket, c.buffer[0..received], linux.MSG.NOSIGNAL);
    }
};
const DiscardCount = struct {
    pub fn call(_: @This(), _: usize) void {}
};
const PeerError = struct {
    pub fn call(_: @This(), err: anyerror) void {
        if (err != error.EndOfStream) std.debug.print("connection: {s}\n", .{@errorName(err)});
    }
};
const Close = struct {
    socket: i32,
    pub fn call(self: @This()) void {
        _ = linux.close(self.socket);
    }
};
const CloseError = struct {
    socket: i32,
    pub fn call(self: @This(), err: anyerror) void {
        _ = linux.close(self.socket);
        std.debug.print("connection: {s}\n", .{@errorName(err)});
    }
};
const CloseStopped = struct {
    socket: i32,
    pub fn call(self: @This()) ex.JustStopped(.{}) {
        _ = linux.close(self.socket);
        return ex.justStopped(ex.Values(.{}));
    }
};
const SpawnEcho = struct {
    scope: *ex.CountingScope,
    allocator: std.mem.Allocator,
    context: *ex.IoUring,
    once: bool,
    pub fn call(self: @This(), socket: i32) !bool {
        // If admission/allocation fails, the task has not started: retain fd
        // ownership here. Once spawned, every completion path closes it.
        errdefer _ = linux.close(socket);
        try ex.spawn(
            ex.schedule(self.context.getScheduler())
                .letValue(Echo, .{ .context = self.context, .socket = socket })
                .then(Close, .{socket})
                .uponError(CloseError, .{socket})
                .letStopped(CloseStopped, .{socket}),
            self.scope.getToken(),
            .{ .allocator = self.allocator },
        );
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

    var scope: ex.CountingScope = .{};
    defer scope.deinit();

    // Exactly one accept is outstanding. spawn returns as soon as the echo task
    // is started/queued, so repeat immediately accepts the next connection.
    const accept_loop = Io.accept(context, listener, linux.SOCK.CLOEXEC)
        .then(SpawnEcho, .{ &scope, allocator, context, once })
        .repeatEffectUntil();
    const server = ex.runInScope(&scope, accept_loop);

    // The only wait includes the accept loop AND all spawned children. --once
    // closes admission after one accept and drains that echo task without stop.
    _ = try server.syncWait(.{});
}
