//! Linux TCP echo server using zigexec + io_uring, without std.Io or libc.
//! Run: zig build run-echo -- [port] [--once]
//! One reactor owns the accept operation and an intrusive list of client operations.
const std = @import("std");
const ex = @import("zigexec");
const linux = std.os.linux;
const Io = ex.io.For(*ex.IoUring);

// Each Client owns this buffer at a stable address until its completion.
// No buffer points into the accept operation or a temporary sender.
const Echo = struct {
    context: *ex.IoUring,
    socket: i32,
    buffer: [16 * 1024]u8 = undefined,

    const Loop = Io.Recv.LetValue(EchoChunk).Then(DiscardCount).Repeat().UponError(PeerError);
    pub fn call(self: *@This()) Loop {
        return Io.recv(self.context, self.socket, &self.buffer, 0)
            .letValue(EchoChunk, .{self})
            .then(DiscardCount, .{})
            .repeat()
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
// Only the reactor accesses the list and operations. No CountingScope, spawn,
// per-client stop source, or extra scheduling hop is needed for dispatch.
const Client = struct {
    server: *Server,
    previous: ?*Client = null,
    next: ?*Client = null,
    echo: Echo,
    operation: ex.Connection(Echo.Loop, *Client) = undefined,

    pub fn getEnv(_: *Client) ex.UnstoppableEnv {
        return .{};
    }
    pub fn setValue(self: *Client, _: *const ex.Values(.{})) void {
        defer self.completeOwnership();
    }
    pub fn setStopped(self: *Client) void {
        defer self.completeOwnership();
    }
    pub fn setError(self: *Client, err: anyerror) void {
        defer self.completeOwnership();
        std.debug.print("connection: {s}\n", .{@errorName(err)});
    }
    fn completeOwnership(self: *Client) void {
        const server = self.server;
        if (self.previous) |previous| previous.next = self.next else server.clients = self.next;
        if (self.next) |next| next.previous = self.previous;
        _ = linux.close(self.echo.socket);
        server.allocator.destroy(self);
        server.finishIfDrained();
    }
};

const Dispatch = struct {
    server: *Server,
    pub fn call(self: @This(), socket: i32) !bool {
        const server = self.server;
        errdefer _ = linux.close(socket);
        const client = try server.allocator.create(Client);
        client.* = .{
            .server = server,
            .next = server.clients,
            .echo = .{ .context = server.context, .socket = socket },
        };
        if (server.clients) |head| head.previous = client;
        server.clients = client;
        ex.connectInto(&client.operation, client.echo.call(), client);
        client.operation.start(); // May synchronously retire and destroy client.
        return server.once;
    }
};

const Server = struct {
    allocator: std.mem.Allocator,
    context: *ex.IoUring,
    listener: i32,
    once: bool,
    clients: ?*Client = null,
    accept_finished: bool = false,
    failure: ?anyerror = null,
    done: ex.RunLoop = .{},
    launch_task: ex.ScheduleTask = .{ .run = launch },
    accept_operation: ex.Connection(AcceptLoop, *Server) = undefined,
    const AcceptLoop = Io.Accept.Then(Dispatch).RepeatUntil();

    pub fn getEnv(_: *Server) ex.UnstoppableEnv {
        return .{};
    }
    pub fn setValue(self: *Server, _: *const ex.Values(.{})) void {
        defer self.completeOwnership();
    }
    pub fn setError(self: *Server, err: anyerror) void {
        defer self.completeOwnership();
        self.failure = err;
        // This context belongs exclusively to the server. Shutdown cancels all
        // pending I/O; clients retire through their real kernel completions.
        self.context.shutdown();
    }
    pub fn setStopped(self: *Server) void {
        defer self.completeOwnership();
        self.setError(error.ServerStopped);
    }
    fn completeOwnership(self: *Server) void {
        self.accept_finished = true;
        self.finishIfDrained();
    }
    fn finishIfDrained(self: *Server) void {
        if (self.accept_finished and self.clients == null) self.done.finish();
    }
    fn launch(task: *ex.ScheduleTask) void {
        const self: *Server = @fieldParentPtr("launch_task", task);
        const sender = Io.accept(self.context, self.listener, linux.SOCK.CLOEXEC)
            .then(Dispatch, .{self}).repeatUntil();
        ex.connectInto(&self.accept_operation, sender, self);
        self.accept_operation.start();
    }
    fn run(self: *Server) !void {
        // Dispatch even the first start to the reactor: an inline failure or
        // start/complete race must not move list bookkeeping onto main.
        try self.context.getScheduler().submit(&self.launch_task);
        self.done.run(); // The only cross-thread notification is final drain.
        if (self.failure) |err| return err;
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

    var server: Server = .{
        .allocator = allocator,
        .context = context,
        .listener = listener,
        .once = once,
    };
    // --once stops accepting after one connection, but waits for its operation
    // to retire. Every list mutation and per-client start runs on the reactor.
    try server.run();
}

test "manual dispatch closes the accepted descriptor when allocation fails" {
    const t = std.testing;
    const context = try ex.IoUring.init(t.allocator, .{});
    defer context.deinit();
    var sockets: [2]i32 = undefined;
    _ = try checked("socketpair", linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sockets));
    defer _ = linux.close(sockets[1]);
    var server: Server = .{ .allocator = t.failing_allocator, .context = context, .listener = -1, .once = false };
    try t.expectError(error.OutOfMemory, (Dispatch{ .server = &server }).call(sockets[0]));
    try t.expectEqual(linux.E.BADF, linux.errno(linux.close(sockets[0])));
    try t.expect(server.clients == null);
}

test "accept failure cancels and drains manually owned client operations" {
    const t = std.testing;
    const context = try ex.IoUring.init(t.allocator, .{ .entries = 2 });
    defer context.deinit();
    var sockets: [2]i32 = undefined;
    _ = try checked("socketpair", linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sockets));
    defer _ = linux.close(sockets[1]);
    var server: Server = .{ .allocator = t.allocator, .context = context, .listener = -1, .once = false };
    const Setup = struct {
        task: ex.ScheduleTask = .{ .run = run },
        server: *Server,
        socket: i32,
        fn run(task: *ex.ScheduleTask) void {
            const self: *@This() = @fieldParentPtr("task", task);
            _ = (Dispatch{ .server = self.server }).call(self.socket) catch @panic("fixture allocation failed");
            // The peer remains open and sends nothing, so this client is pending
            // until the invalid listener causes server-wide context shutdown.
            Server.launch(&self.server.launch_task);
        }
    };
    var setup: Setup = .{ .server = &server, .socket = sockets[0] };
    try context.getScheduler().submit(&setup.task);
    server.done.run();
    try t.expectEqual(error.BadFileDescriptor, server.failure.?);
    try t.expect(server.accept_finished);
    try t.expect(server.clients == null);
    try t.expectEqual(linux.E.BADF, linux.errno(linux.close(sockets[0])));
}
