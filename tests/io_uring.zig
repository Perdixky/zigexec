const std = @import("std");
const ex = @import("zigexec");
const linux = std.os.linux;
const t = std.testing;
const Event = @import("support.zig").Event;
fn fd(result: usize) !i32 {
    if (linux.errno(result) != .SUCCESS) return error.FixtureSyscallFailed;
    return @intCast(result);
}
fn checked(result: usize) !void {
    if (linux.errno(result) != .SUCCESS) return error.FixtureSyscallFailed;
}

test "io_uring schedules and performs real file I/O and EOF" {
    const context = try ex.IoUring.init(t.allocator, .{});
    defer context.deinit();
    try t.expect((try context.getScheduler().schedule().syncWait(.{})) != null);
    const file = try fd(linux.memfd_create("zigexec-test", linux.MFD.CLOEXEC));
    defer _ = linux.close(file);
    try t.expectEqual(5, (try ex.io.writeSome(context, file, "hello", 0).syncWait(.{})).?[0]);
    var buffer: [16]u8 = undefined;
    const n = (try ex.io.readSome(context, file, &buffer, 0).syncWait(.{})).?[0];
    try t.expectEqualStrings("hello", buffer[0..n]);
    try t.expectEqual(0, (try ex.io.readSome(context, file, &buffer, 100).syncWait(.{})).?[0]);
    try t.expect((try ex.io.fsync(context, file).syncWait(.{})) != null);
}

test "io_uring opens closes and reports kernel errors" {
    const context = try ex.IoUring.init(t.allocator, .{});
    defer context.deinit();
    const flags: u32 = @bitCast(linux.O{ .CLOEXEC = true });
    const file = (try ex.io.openAt(context, linux.AT.FDCWD, "/dev/null", flags, 0).syncWait(.{ .allocator = std.testing.allocator })).?[0];
    _ = try ex.io.close(context, file).syncWait(.{ .allocator = std.testing.allocator });
    var buffer: [1]u8 = undefined;
    try t.expectError(error.BadFileDescriptor, ex.io.readSome(context, -1, &buffer, 0).syncWait(.{ .allocator = std.testing.allocator }));
    try t.expectError(error.FileNotFound, ex.io.openAt(context, linux.AT.FDCWD, "/zigexec-does-not-exist/no-file", flags, 0).syncWait(.{ .allocator = std.testing.allocator }));
}

test "io_uring timers complete and support pre-start cancellation" {
    const context = try ex.IoUring.init(t.allocator, .{});
    defer context.deinit();
    _ = try ex.io.sleepFor(context, std.time.ns_per_ms).syncWait(.{ .allocator = std.testing.allocator });
    var stop: ex.StopSource = .{};
    defer stop.deinit();
    _ = stop.requestStop();
    try t.expectEqual(null, try ex.io.sleepFor(context, 60 * std.time.ns_per_s).withStopToken(stop.token()).syncWait(.{ .allocator = std.testing.allocator }));
}

test "socket send and recv overlap even with a two-entry ring" {
    const context = try ex.IoUring.init(t.allocator, .{ .entries = 2 });
    defer context.deinit();
    var sockets: [2]i32 = undefined;
    try checked(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sockets));
    defer _ = linux.close(sockets[0]);
    defer _ = linux.close(sockets[1]);
    var buffer: [4]u8 = undefined;
    const result = (try ex.whenAll(.{
        ex.io.recv(context, sockets[0], &buffer, 0),
        ex.io.send(context, sockets[1], "ping", 0),
    }).syncWait(.{ .allocator = std.testing.allocator })).?;
    try t.expectEqual(4, result[0]);
    try t.expectEqual(4, result[1]);
    try t.expectEqualStrings("ping", &buffer);
}

test "stop callback cancels a pending socket receive and a long timer" {
    const context = try ex.IoUring.init(t.allocator, .{ .entries = 2 });
    defer context.deinit();
    var sockets: [2]i32 = undefined;
    try checked(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sockets));
    defer _ = linux.close(sockets[0]);
    defer _ = linux.close(sockets[1]);
    var buffer: [8]u8 = undefined;
    var source: ex.StopSource = .{};
    defer source.deinit();
    const Cancel = struct {
        source: *ex.StopSource,
        pub fn call(self: @This()) void {
            _ = self.source.requestStop();
        }
    };
    const work = ex.whenAll(.{
        ex.whenAll(.{ ex.io.recv(context, sockets[0], &buffer, 0), ex.io.sleepFor(context, 60 * std.time.ns_per_s) }).withStopToken(source.token()),
        ex.io.sleepFor(context, std.time.ns_per_ms).then(Cancel, .{ .source = &source }),
    });
    try t.expectEqual(null, try work.syncWait(.{ .allocator = std.testing.allocator }));
}

test "shutdown cancels outstanding work and rejects new submissions" {
    const context = try ex.IoUring.init(t.allocator, .{});
    defer context.deinit();
    const Receiver = struct {
        done: Event = .{},
        stopped: bool = false,
        pub fn getEnv(_: *@This()) ex.Env {
            return .{ .allocator = std.testing.allocator };
        }
        pub fn setValue(self: *@This(), _: *const @Tuple(&.{})) void {
            defer self.completeOwnership();
            @panic("unexpected timer expiration");
        }
        pub fn setError(self: *@This(), _: anyerror) void {
            defer self.completeOwnership();
            @panic("unexpected error");
        }
        pub fn setStopped(self: *@This()) void {
            defer self.completeOwnership();
            self.stopped = true;
        }
        fn completeOwnership(self: *@This()) void {
            self.done.set();
        }
    };
    var receiver: Receiver = .{};
    var operation: ex.Connection(@TypeOf(ex.io.sleepFor(context, 60 * std.time.ns_per_s)), @TypeOf(&receiver)) = undefined;
    ex.connectInto(&operation, ex.io.sleepFor(context, 60 * std.time.ns_per_s), &receiver);
    operation.start();
    context.shutdown();
    receiver.done.wait();
    try t.expect(receiver.stopped);
    try t.expectError(error.ContextClosed, ex.io.sleepFor(context, 1).syncWait(.{ .allocator = std.testing.allocator }));
}

test "io_uring connect and accept use real loopback sockets" {
    const context = try ex.IoUring.init(t.allocator, .{});
    defer context.deinit();
    const listener = try fd(linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0));
    defer _ = linux.close(listener);
    var address: linux.sockaddr.in = .{ .port = 0, .addr = @bitCast([4]u8{ 127, 0, 0, 1 }) };
    try checked(linux.bind(listener, @ptrCast(&address), @sizeOf(@TypeOf(address))));
    try checked(linux.listen(listener, 8));
    var length: linux.socklen_t = @sizeOf(@TypeOf(address));
    try checked(linux.getsockname(listener, @ptrCast(&address), &length));
    const client = try fd(linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0));
    defer _ = linux.close(client);
    const result = (try ex.whenAll(.{
        ex.io.accept(context, listener, linux.SOCK.CLOEXEC),
        ex.io.connect(context, client, @ptrCast(&address), length),
    }).syncWait(.{ .allocator = std.testing.allocator })).?;
    defer _ = linux.close(result[0]);
    var buffer: [2]u8 = undefined;
    _ = try ex.whenAll(.{ ex.io.send(context, client, "ok", 0), ex.io.recv(context, result[0], &buffer, 0) }).syncWait(.{ .allocator = std.testing.allocator });
    try t.expectEqualStrings("ok", &buffer);
}

test "io_uring initialization rejects invalid size and reports allocation failure" {
    try t.expectError(error.InvalidRingSize, ex.IoUring.init(t.allocator, .{ .entries = 1 }));
    try t.expectError(error.InvalidRingSize, ex.IoUring.init(t.allocator, .{ .entries = 3 }));
    try t.expectError(error.OutOfMemory, ex.IoUring.init(t.failing_allocator, .{}));
}

test "queue pressure flushes blocking receives before their later send" {
    const context = try ex.IoUring.init(t.allocator, .{ .entries = 2 });
    defer context.deinit();
    var sockets: [2]i32 = undefined;
    try checked(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sockets));
    defer _ = linux.close(sockets[0]);
    defer _ = linux.close(sockets[1]);
    const count = 128;
    var buffers: [count][1]u8 = undefined;
    const Receiver = struct {
        remaining: std.atomic.Value(usize) = .init(count),
        failed: std.atomic.Value(bool) = .init(false),
        done: Event = .{},
        fn completeOwnership(self: *@This()) void {
            if (self.remaining.fetchSub(1, .acq_rel) == 1) self.done.set();
        }
        pub fn getEnv(_: *@This()) ex.Env {
            return .{ .allocator = std.testing.allocator };
        }
        pub fn setValue(self: *@This(), value: *const @Tuple(&.{usize})) void {
            defer self.completeOwnership();
            if (value.*[0] != 1) self.failed.store(true, .release);
        }
        pub fn setError(self: *@This(), _: anyerror) void {
            defer self.completeOwnership();
            self.failed.store(true, .release);
        }
        pub fn setStopped(self: *@This()) void {
            defer self.completeOwnership();
            self.failed.store(true, .release);
        }
    };
    var receiver: Receiver = .{};
    const Operation = ex.Connection(@TypeOf(ex.io.recv(context, sockets[0], &buffers[0], 0)), *Receiver);
    var operations: [count]Operation = undefined;
    for (&operations, &buffers) |*operation, *buffer| {
        ex.connectInto(operation, ex.io.recv(context, sockets[0], buffer, 0), &receiver);
        operation.start();
    }
    const data: [count]u8 = @splat('x');
    try t.expectEqual(count, (try ex.io.send(context, sockets[1], &data, 0).syncWait(.{ .allocator = std.testing.allocator })).?[0]);
    receiver.done.wait();
    try t.expect(!receiver.failed.load(.acquire));
    for (buffers) |buffer| try t.expectEqual(@as(u8, 'x'), buffer[0]);
}

test "repeated in-flight cancellation safely reuses operation addresses" {
    const context = try ex.IoUring.init(t.allocator, .{ .entries = 2 });
    defer context.deinit();
    const Receiver = struct {
        done: Event = .{},
        pub fn getEnv(_: *@This()) ex.Env {
            return .{ .allocator = std.testing.allocator };
        }
        pub fn setValue(self: *@This(), _: *const @Tuple(&.{})) void {
            defer self.completeOwnership();
            @panic("timer unexpectedly elapsed");
        }
        pub fn setError(self: *@This(), _: anyerror) void {
            defer self.completeOwnership();
            @panic("unexpected timer error");
        }
        pub fn setStopped(self: *@This()) void {
            defer self.completeOwnership();
        }
        fn completeOwnership(self: *@This()) void {
            self.done.set();
        }
    };
    for (0..100) |_| {
        var source: ex.StopSource = .{};
        var receiver: Receiver = .{};
        var operation: ex.Connection(@TypeOf(ex.io.sleepFor(context, 60 * std.time.ns_per_s).withStopToken(source.token())), @TypeOf(&receiver)) = undefined;
        ex.connectInto(&operation, ex.io.sleepFor(context, 60 * std.time.ns_per_s).withStopToken(source.token()), &receiver);
        operation.start();
        _ = try context.getScheduler().schedule().syncWait(.{ .allocator = std.testing.allocator });
        _ = source.requestStop();
        receiver.done.wait();
        source.deinit();
    }
}

test "I/O completion may release its root connection" {
    const context = try ex.IoUring.init(t.allocator, .{});
    defer context.deinit();
    const sender = ex.io.sleepFor(context, std.time.ns_per_ms);
    const Receiver = struct {
        const Operation = ex.Connection(@TypeOf(sender), *@This());
        operation: *Operation,
        done: Event = .{},
        pub fn getEnv(_: *@This()) ex.Env {
            return .{ .allocator = std.testing.allocator };
        }
        pub fn setValue(self: *@This(), _: *const @Tuple(&.{})) void {
            defer self.completeOwnership();
        }
        fn completeOwnership(self: *@This()) void {
            t.allocator.destroy(self.operation);
            self.done.set();
        }
        pub fn setError(self: *@This(), _: anyerror) void {
            defer self.completeOwnership();
            @panic("unexpected I/O error");
        }
        pub fn setStopped(self: *@This()) void {
            defer self.completeOwnership();
            @panic("unexpected stopped");
        }
    };
    const Operation = Receiver.Operation;
    const operation = try t.allocator.create(Operation);
    var receiver: Receiver = .{ .operation = operation };
    ex.connectInto(operation, sender, &receiver);
    operation.start();
    receiver.done.wait();
}

test "a shared timer executes once and survives owner release during pending I/O" {
    const context = try ex.IoUring.init(t.allocator, .{});
    defer context.deinit();
    var shared = try ex.io.sleepFor(context, std.time.ns_per_ms).split(t.allocator);
    const Receiver = struct {
        done: Event = .{},
        pub fn getEnv(_: *@This()) ex.Env {
            return .{ .allocator = std.testing.allocator };
        }
        pub fn setValue(self: *@This(), _: *const ex.Values(.{})) void {
            defer self.completeOwnership();
        }
        fn completeOwnership(self: *@This()) void {
            self.done.set();
        }
        pub fn setError(self: *@This(), _: anyerror) void {
            defer self.completeOwnership();
            @panic("unexpected I/O error");
        }
        pub fn setStopped(self: *@This()) void {
            defer self.completeOwnership();
            @panic("unexpected stopped");
        }
    };
    var receiver: Receiver = .{};
    var operation: ex.Connection(@TypeOf(ex.whenAll(.{ shared.sender(), shared.sender() })), @TypeOf(&receiver)) = undefined;
    ex.connectInto(&operation, ex.whenAll(.{ shared.sender(), shared.sender() }), &receiver);
    operation.start();
    shared.deinit();
    receiver.done.wait();
}

test "reactor callbacks can request shutdown without self-joining" {
    const context = try ex.IoUring.init(t.allocator, .{});
    defer context.deinit();
    const Shutdown = struct {
        context: *ex.IoUring,
        pub fn call(self: @This()) void {
            self.context.shutdown();
        }
    };
    _ = try context.getScheduler().schedule().then(Shutdown, .{ .context = context }).syncWait(.{ .allocator = std.testing.allocator });
    try t.expectError(error.ContextClosed, context.getScheduler().schedule().syncWait(.{ .allocator = std.testing.allocator }));
}

test "invalid buffers are rejected before kernel submission" {
    const context = try ex.IoUring.init(t.allocator, .{});
    defer context.deinit();
    var byte: u8 = 0;
    const buffer = @as([*]u8, @ptrCast(&byte))[0 .. @as(usize, std.math.maxInt(u32)) + 1];
    try t.expectError(error.InvalidBufferLength, ex.io.readSome(context, -1, buffer, 0).syncWait(.{ .allocator = std.testing.allocator }));
}

test "scoped io_uring chain forwards allocated slices and retains factory-owned buffers" {
    const Io = ex.io.For(*ex.IoUring);
    const Buffer = [5]u8;
    const Write = struct {
        context: *ex.IoUring,
        file: i32,
        pub fn call(self: @This(), bytes: []const u8) Io.WriteSome {
            return Io.writeSome(self.context, self.file, bytes, 0);
        }
    };
    const Read = struct {
        context: *ex.IoUring,
        file: i32,
        observed: *?*Buffer,
        buffer: Buffer = undefined,
        pub fn call(self: *@This(), count: usize) Io.ReadSome {
            self.observed.* = &self.buffer;
            return Io.readSome(self.context, self.file, self.buffer[0..count], 0);
        }
    };
    const Decode = struct {
        observed: *?*Buffer,
        pub fn call(self: @This(), count: usize) !usize {
            try t.expectEqualStrings("hello", self.observed.*.?[0..count]);
            return count;
        }
    };
    const context = try ex.IoUring.init(t.allocator, .{});
    defer context.deinit();
    const file = try fd(linux.memfd_create("zigexec-scope", linux.MFD.CLOEXEC));
    defer _ = linux.close(file);
    var observed: ?*Buffer = null;
    const bytes = try t.allocator.dupe(u8, "hello");
    defer t.allocator.free(bytes);
    const task = ex.just(bytes).letValue(ex.upstream()
        .letValue(Write, .{ context, file })
        .letValue(ex.upstream()
        .letValue(Read, .{ .context = context, .file = file, .observed = &observed })
        .then(Decode, .{&observed}), .{}), .{});
    try t.expectEqual(5, (try task.syncWait(.{ .allocator = std.testing.allocator })).?[0]);
    // observed is now expired; consumers must finish reading inside the scope.
}

test "task scope drains real I/O children after successful producer" {
    const context = try ex.IoUring.init(t.allocator, .{ .entries = 2 });
    defer context.deinit();
    var scope: ex.CountingScope = .{};
    defer scope.deinit();
    const Handle = struct {
        pub fn call(_: @This(), err: anyerror) void {
            std.debug.panic("unexpected {s}", .{@errorName(err)});
        }
    };
    for (0..32) |_| try ex.spawn(ex.io.sleepFor(context, std.time.ns_per_ms).uponError(Handle, .{}), scope.getToken(), .{ .allocator = t.allocator });
    try t.expect((try ex.runInScope(&scope, ex.just(.{})).syncWait(.{})) != null);
}

test "task scope producer failure cancels and retires pending kernel receives" {
    const context = try ex.IoUring.init(t.allocator, .{ .entries = 2 });
    defer context.deinit();
    var sockets: [2]i32 = undefined;
    try checked(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sockets));
    defer _ = linux.close(sockets[0]);
    defer _ = linux.close(sockets[1]);
    const Discard = struct {
        pub fn call(_: @This(), _: usize) void {}
    };
    var buffers: [32][8]u8 = undefined;
    var scope: ex.CountingScope = .{};
    defer scope.deinit();
    const Handle = struct {
        pub fn call(_: @This(), err: anyerror) void {
            std.debug.panic("unexpected {s}", .{@errorName(err)});
        }
    };
    for (&buffers) |*buffer| try ex.spawn(ex.io.recv(context, sockets[0], buffer, 0).then(Discard, .{}).uponError(Handle, .{}), scope.getToken(), .{ .allocator = t.allocator });
    // Pass through the same reactor before failing the producer, so reads have
    // reached the kernel. Cancellation must wait for both target and cancel CQEs.
    const producer = ex.schedule(context.getScheduler()).letValue(ex.justError(ex.Values(.{}), error.AcceptFailed), .{});
    try t.expectError(error.AcceptFailed, ex.runInScope(&scope, producer).syncWait(.{}));
}

test "counting join uses io_uring scheduler supplied by receiver environment" {
    const context = try ex.IoUring.init(t.allocator, .{});
    defer context.deinit();
    const scheduler = context.getScheduler();
    const Current = struct {
        pub fn call(_: @This()) std.Thread.Id {
            return std.Thread.getCurrentId();
        }
    };
    const reactor_id = (try ex.schedule(scheduler).then(Current, .{}).syncWait(.{})).?[0];
    var scope: ex.SimpleCountingScope = .{};
    defer scope.deinit();
    var association = scope.getToken().tryAssociate();
    const Capture = struct {
        scheduler: ex.StartScheduler,
        done: Event = .{},
        id: std.Thread.Id = undefined,
        pub fn getEnv(self: *@This()) ex.Env {
            return .{ .start_scheduler = self.scheduler };
        }
        pub fn setValue(self: *@This(), _: *const ex.Values(.{})) void {
            defer self.completeOwnership();
            self.id = std.Thread.getCurrentId();
        }
        pub fn setError(self: *@This(), _: anyerror) void {
            defer self.completeOwnership();
            @panic("unexpected scheduling error");
        }
        pub fn setStopped(self: *@This()) void {
            defer self.completeOwnership();
            @panic("unexpected stopped");
        }
        fn completeOwnership(self: *@This()) void {
            self.done.set();
        }
    };
    var capture: Capture = .{ .scheduler = ex.StartScheduler.init(&scheduler) };
    var join: ex.Connection(@TypeOf(scope.join()), @TypeOf(&capture)) = undefined;
    ex.connectInto(&join, scope.join(), &capture);
    join.start();
    association.deinit();
    capture.done.wait();
    try t.expectEqual(reactor_id, capture.id);
}

test "io_uring erased start scheduler schedules and rejects after shutdown" {
    const context = try ex.IoUring.init(t.allocator, .{});
    defer context.deinit();
    const scheduler = context.getScheduler();
    const erased = ex.StartScheduler.init(&scheduler);
    _ = try ex.schedule(erased).syncWait(.{});
    context.shutdown();
    try t.expectError(error.ContextClosed, ex.schedule(erased).syncWait(.{}));
}

test "shutdown drains erased scheduler jobs already accepted behind a busy reactor" {
    const context = try ex.IoUring.init(t.allocator, .{});
    defer context.deinit();
    const scheduler = context.getScheduler();
    const erased = ex.StartScheduler.init(&scheduler);
    const Capture = struct {
        done: Event = .{},
        pub fn getEnv(_: *@This()) ex.Env {
            return .{};
        }
        pub fn setValue(self: *@This(), _: *const ex.Values(.{})) void {
            defer self.completeOwnership();
        }
        pub fn setError(self: *@This(), _: anyerror) void {
            defer self.completeOwnership();
            @panic("accepted task lost");
        }
        pub fn setStopped(self: *@This()) void {
            defer self.completeOwnership();
            @panic("unexpected cancellation");
        }
        fn completeOwnership(self: *@This()) void {
            self.done.set();
        }
    };
    const Block = struct {
        entered: *Event,
        release: *Event,
        pub fn call(self: @This()) void {
            self.entered.set();
            self.release.wait();
        }
    };
    var entered: Event = .{};
    var release: Event = .{};
    var first: Capture = .{};
    var blocker: ex.Connection(@TypeOf(ex.schedule(erased).then(Block, .{ &entered, &release })), @TypeOf(&first)) = undefined;
    ex.connectInto(&blocker, ex.schedule(erased).then(Block, .{ &entered, &release }), &first);
    blocker.start();
    entered.wait();
    var captures: [32]Capture = @splat(.{});
    var ops: [32]ex.Connection(ex.Schedule(ex.StartScheduler), *Capture) = undefined;
    for (&ops, &captures) |*op, *capture| {
        ex.connectInto(op, ex.schedule(erased), capture);
        op.start();
    }
    context.shutdown();
    release.set();
    first.done.wait();
    for (&captures) |*capture| capture.done.wait();
}

test "whenAny timeout drains cancelled recv before downstream reuses the buffer" {
    const context = try ex.IoUring.init(t.allocator, .{ .entries = 2 });
    defer context.deinit();
    var sockets: [2]i32 = undefined;
    try checked(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sockets));
    defer _ = linux.close(sockets[0]);
    defer _ = linux.close(sockets[1]);
    var buffer: [4]u8 = undefined;
    const ReadAgain = struct {
        context: *ex.IoUring,
        socket: i32,
        peer: i32,
        buffer: []u8,
        pub fn call(self: @This(), result: anytype) ex.WhenAll(.{ ex.io.Recv(*ex.IoUring), ex.io.Send(*ex.IoUring) }) {
            std.debug.assert(result == .timeout);
            return ex.whenAll(.{
                ex.io.recv(self.context, self.socket, self.buffer, 0),
                ex.io.send(self.context, self.peer, "ping", 0),
            });
        }
    };
    for (0..10) |_| {
        const result = (try ex.whenAny(.{
            .read = ex.io.recv(context, sockets[0], &buffer, 0),
            .timeout = ex.io.sleepFor(context, std.time.ns_per_ms),
        }).letValue(ReadAgain, .{ context, sockets[0], sockets[1], &buffer }).syncWait(.{})).?;
        try t.expectEqual(4, result[0]);
        try t.expectEqualStrings("ping", &buffer);
    }
    _ = try ex.io.send(context, sockets[1], "pong", 0).syncWait(.{});
    const result = (try ex.whenAny(.{
        .read = ex.io.recv(context, sockets[0], &buffer, 0),
        .timeout = ex.io.sleepFor(context, 60 * std.time.ns_per_s),
    }).syncWait(.{})).?[0];
    try t.expect(result == .read);
    try t.expectEqual(4, result.read[0]);
    try t.expectEqualStrings("pong", &buffer);
}

test "event-triggered cancellation retries a full SQ and drains local submissions" {
    const context = try ex.IoUring.init(t.allocator, .{ .entries = 2 });
    defer context.deinit();
    var source: ex.StopSource = .{};
    defer source.deinit();
    const count = 128;
    const Capture = struct {
        remaining: std.atomic.Value(usize) = .init(count),
        done: Event = .{},
        pub fn getEnv(_: *@This()) ex.Env {
            return .{};
        }
        pub fn setValue(self: *@This(), _: *const ex.Values(.{})) void {
            defer self.completeOwnership();
            @panic("timer elapsed");
        }
        pub fn setError(self: *@This(), _: anyerror) void {
            defer self.completeOwnership();
            @panic("timer failed");
        }
        pub fn setStopped(self: *@This()) void {
            defer self.completeOwnership();
        }
        fn completeOwnership(self: *@This()) void {
            if (self.remaining.fetchSub(1, .acq_rel) == 1) self.done.set();
        }
    };
    // Schedule arrives through the shared inbox, then starts the timer locally.
    const sender = ex.io.sleepFor(context, 60 * std.time.ns_per_s).startsOn(context.getScheduler()).withStopToken(source.token());
    var capture: Capture = .{};
    var operations: [count]ex.Connection(@TypeOf(sender), *Capture) = undefined;
    for (&operations) |*op| {
        ex.connectInto(op, sender, &capture);
        op.start();
    }
    _ = try context.getScheduler().schedule().syncWait(.{});
    _ = source.requestStop();
    capture.done.wait();
}

test "reactor local scheduler submissions defer to the next batch without a wake" {
    const context = try ex.IoUring.init(t.allocator, .{ .entries = 2 });
    defer context.deinit();
    const State = struct {
        task: ex.ScheduleTask = .{ .run = run },
        scheduler: ex.IoUring.Scheduler,
        calls: usize = 0,
        done: Event = .{},
        fn run(task: *ex.ScheduleTask) void {
            const self: *@This() = @fieldParentPtr("task", task);
            self.calls += 1;
            if (self.calls == 10_000) return self.done.set();
            const before = self.calls;
            self.scheduler.submit(task) catch @panic("unexpected shutdown");
            std.debug.assert(self.calls == before);
        }
    };
    var state: State = .{ .scheduler = context.getScheduler() };
    try state.scheduler.submit(&state.task);
    state.done.wait();
    try t.expectEqual(10_000, state.calls);
}

test "both ring modes perform I/O, cancel in flight, and drain non-cancellable work on shutdown" {
    for ([_]bool{ true, false }) |defer_taskrun| {
        const context = try ex.IoUring.init(t.allocator, .{ .entries = 2, .defer_taskrun = defer_taskrun });
        defer context.deinit();
        var sockets: [2]i32 = undefined;
        try checked(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sockets));
        defer _ = linux.close(sockets[0]);
        defer _ = linux.close(sockets[1]);

        var buffer: [4]u8 = undefined;
        const echoed = (try ex.whenAll(.{
            ex.io.recv(context, sockets[0], &buffer, 0),
            ex.io.send(context, sockets[1], "ping", 0),
        }).syncWait(.{})).?;
        try t.expectEqual(4, echoed[0]);
        try t.expectEqualStrings("ping", &buffer);

        // In flight, cancellable: reaches the kernel through the active list.
        var source: ex.StopSource = .{};
        defer source.deinit();
        const Cancel = struct {
            source: *ex.StopSource,
            pub fn call(self: @This()) void {
                _ = self.source.requestStop();
            }
        };
        try t.expectEqual(null, try ex.whenAll(.{
            ex.io.recv(context, sockets[0], &buffer, 0).withStopToken(source.token()),
            ex.io.sleepFor(context, std.time.ns_per_ms).then(Cancel, .{ .source = &source }),
        }).syncWait(.{}));

        // In flight, not cancellable (unstoppable env): only shutdown's single
        // cancel-all can reach it, since it never joins the active list.
        const Receiver = struct {
            done: Event = .{},
            stopped: bool = false,
            pub fn getEnv(_: *@This()) ex.UnstoppableEnv {
                return .{};
            }
            pub fn setValue(self: *@This(), _: *const @Tuple(&.{usize})) void {
                self.done.set();
            }
            pub fn setError(self: *@This(), _: anyerror) void {
                self.done.set();
            }
            pub fn setStopped(self: *@This()) void {
                self.stopped = true;
                self.done.set();
            }
        };
        var receiver: Receiver = .{};
        const pending = ex.io.recv(context, sockets[0], &buffer, 0);
        var operation: ex.Connection(@TypeOf(pending), *Receiver) = undefined;
        ex.connectInto(&operation, pending, &receiver);
        operation.start();
        // Submitted in the same reactor batch as, and before, this nop.
        _ = try context.getScheduler().schedule().syncWait(.{});
        context.shutdown();
        receiver.done.wait();
        try t.expect(receiver.stopped);
    }
}
