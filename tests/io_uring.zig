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
    try t.expect((try context.getScheduler().schedule().syncWait(.{ .allocator = std.testing.allocator })) != null);
    const file = try fd(linux.memfd_create("zigexec-test", linux.MFD.CLOEXEC));
    defer _ = linux.close(file);
    try t.expectEqual(5, (try ex.io.writeSome(context, file, "hello", 0).syncWait(.{ .allocator = std.testing.allocator })).?[0]);
    var buffer: [16]u8 = undefined;
    const n = (try ex.io.readSome(context, file, &buffer, 0).syncWait(.{ .allocator = std.testing.allocator })).?[0];
    try t.expectEqualStrings("hello", buffer[0..n]);
    try t.expectEqual(0, (try ex.io.readSome(context, file, &buffer, 100).syncWait(.{ .allocator = std.testing.allocator })).?[0]);
    try t.expect((try ex.io.fsync(context, file).syncWait(.{ .allocator = std.testing.allocator })) != null);
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
        pub fn setValue(_: *@This(), _: @Tuple(&.{})) void {
            @panic("unexpected timer expiration");
        }
        pub fn setError(_: *@This(), _: anyerror) void {
            @panic("unexpected error");
        }
        pub fn setStopped(self: *@This()) void {
            self.stopped = true;
            self.done.set();
        }
    };
    var receiver: Receiver = .{};
    var operation = ex.connect(ex.io.sleepFor(context, 60 * std.time.ns_per_s), &receiver);
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
        fn finish(self: *@This()) void {
            if (self.remaining.fetchSub(1, .acq_rel) == 1) self.done.set();
        }
        pub fn getEnv(_: *@This()) ex.Env {
            return .{ .allocator = std.testing.allocator };
        }
        pub fn setValue(self: *@This(), value: @Tuple(&.{usize})) void {
            if (value[0] != 1) self.failed.store(true, .release);
            self.finish();
        }
        pub fn setError(self: *@This(), _: anyerror) void {
            self.failed.store(true, .release);
            self.finish();
        }
        pub fn setStopped(self: *@This()) void {
            self.failed.store(true, .release);
            self.finish();
        }
    };
    var receiver: Receiver = .{};
    const Operation = @TypeOf(ex.io.recv(context, sockets[0], &buffers[0], 0)).Operation;
    var operations: [count]Operation = undefined;
    for (&operations, &buffers) |*operation, *buffer| {
        operation.* = ex.connect(ex.io.recv(context, sockets[0], buffer, 0), &receiver);
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
        pub fn setValue(_: *@This(), _: @Tuple(&.{})) void {
            @panic("timer unexpectedly elapsed");
        }
        pub fn setError(_: *@This(), _: anyerror) void {
            @panic("unexpected timer error");
        }
        pub fn setStopped(self: *@This()) void {
            self.done.set();
        }
    };
    for (0..100) |_| {
        var source: ex.StopSource = .{};
        var receiver: Receiver = .{};
        var operation = ex.connect(ex.io.sleepFor(context, 60 * std.time.ns_per_s).withStopToken(source.token()), &receiver);
        operation.start();
        _ = try context.getScheduler().schedule().syncWait(.{ .allocator = std.testing.allocator });
        _ = source.requestStop();
        receiver.done.wait();
        source.deinit();
    }
}

test "I/O completion may release its operation immediately" {
    const context = try ex.IoUring.init(t.allocator, .{});
    defer context.deinit();
    const sender = ex.io.sleepFor(context, std.time.ns_per_ms);
    const Operation = @TypeOf(sender).Operation;
    const Receiver = struct {
        operation: *Operation,
        done: Event = .{},
        pub fn getEnv(_: *@This()) ex.Env {
            return .{ .allocator = std.testing.allocator };
        }
        pub fn setValue(self: *@This(), _: @Tuple(&.{})) void {
            t.allocator.destroy(self.operation);
            self.done.set();
        }
        pub fn setError(_: *@This(), _: anyerror) void {
            @panic("unexpected I/O error");
        }
        pub fn setStopped(_: *@This()) void {
            @panic("unexpected stopped");
        }
    };
    const operation = try t.allocator.create(Operation);
    var receiver: Receiver = .{ .operation = operation };
    operation.* = ex.connect(sender, &receiver);
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
        pub fn setValue(self: *@This(), _: @Tuple(&.{})) void {
            self.done.set();
        }
        pub fn setError(_: *@This(), _: anyerror) void {
            @panic("unexpected I/O error");
        }
        pub fn setStopped(_: *@This()) void {
            @panic("unexpected stopped");
        }
    };
    var receiver: Receiver = .{};
    var operation = ex.connect(ex.whenAll(.{ shared.sender(), shared.sender() }), &receiver);
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
