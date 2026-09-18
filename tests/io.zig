const std = @import("std");
const ex = @import("zigexec");
const t = std.testing;

// This deliberately synchronous backend validates the I/O sender protocol
// independently of Linux, including inline completion and cancellation cleanup.
pub const Backend = struct {
    calls: usize = 0,
    pub const Request = struct {
        description: ex.io.Description,
        context: *anyopaque,
        complete: *const fn (*anyopaque, ex.io.Result) void,
        canceled: bool = false,
    };
    pub fn cancel(_: *Backend, request: *Request) void {
        request.canceled = true;
    }
    pub fn submit(self: *Backend, request: *Request) void {
        self.calls += 1;
        if (request.canceled) return request.complete(request.context, .stopped);
        const value: usize = switch (request.description) {
            .read => |args| value: {
                @memcpy(args.buffer[0..3], "abc");
                break :value 3;
            },
            .write => |args| args.buffer.len,
            else => 0,
        };
        request.complete(request.context, .{ .value = value });
    }
};

test "I/O senders are lazy and work with a different backend" {
    var backend: Backend = .{};
    var buffer: [4]u8 = undefined;
    const sender = ex.io.readSome(&backend, 1, &buffer, 0);
    try t.expectEqual(0, backend.calls);
    try t.expectEqual(3, (try sender.syncWait(.{ .allocator = std.testing.allocator })).?[0]);
    try t.expectEqualStrings("abc", buffer[0..3]);
    try t.expectEqual(1, backend.calls);
}

test "I/O pre-cancel unregisters callback before inline completion" {
    var backend: Backend = .{};
    var source: ex.StopSource = .{};
    _ = source.requestStop();
    try t.expectEqual(null, try ex.io.sleepFor(&backend, 100).withStopToken(source.token()).syncWait(.{ .allocator = std.testing.allocator }));
    source.deinit();
}

const ShortSendBackend = struct {
    calls: usize = 0,
    total: usize = 0,
    first: ?[*]const u8 = null,
    zero: bool = false,
    fail_after: ?usize = null,
    stop: ?*ex.StopSource = null,
    pub const Request = Backend.Request;
    pub fn cancel(_: *@This(), request: *Request) void {
        request.canceled = true;
    }
    pub fn submit(self: *@This(), request: *Request) void {
        self.calls += 1;
        if (request.canceled) return request.complete(request.context, .stopped);
        if (self.fail_after) |limit| {
            if (self.calls > limit) return request.complete(request.context, .{ .err = error.ConnectionReset });
        }
        const bytes = request.description.send.buffer;
        if (self.first) |ptr| {
            std.debug.assert(bytes.ptr == ptr + self.total);
        } else self.first = bytes.ptr;
        const count = if (self.zero) 0 else @min(bytes.len, 3);
        self.total += count;
        if (self.stop) |source| _ = source.requestStop();
        request.complete(request.context, .{ .value = count });
    }
};

test "sendAll retries short sends at the correct offset without recursive growth" {
    var backend: ShortSendBackend = .{};
    const bytes = try t.allocator.alloc(u8, 300_000);
    defer t.allocator.free(bytes);
    const task: ex.io.SendAll(*ShortSendBackend) = ex.io.sendAll(&backend, 1, bytes, 0);
    try t.expectEqual(300_000, (try task.syncWait(.{ .allocator = std.testing.allocator })).?[0]);
    try t.expectEqual(100_000, backend.calls);
    try t.expectEqual(300_000, backend.total);
}

test "sendAll handles empty buffers zero progress failure and stop between writes" {
    var backend: ShortSendBackend = .{};
    try t.expectEqual(0, (try ex.io.sendAll(&backend, 1, "", 0).syncWait(.{ .allocator = std.testing.allocator })).?[0]);
    try t.expectEqual(0, backend.calls);
    backend.zero = true;
    try t.expectError(error.WriteZero, ex.io.sendAll(&backend, 1, "abc", 0).syncWait(.{ .allocator = std.testing.allocator }));
    backend = .{ .fail_after = 1 };
    try t.expectError(error.ConnectionReset, ex.io.sendAll(&backend, 1, "abcdef", 0).syncWait(.{ .allocator = std.testing.allocator }));
    try t.expectEqual(3, backend.total);
    var source: ex.StopSource = .{};
    defer source.deinit();
    backend = .{ .stop = &source };
    try t.expectEqual(null, try ex.io.sendAll(&backend, 1, "abcdef", 0).withStopToken(source.token()).syncWait(.{ .allocator = std.testing.allocator }));
    try t.expectEqual(1, backend.calls);
    try t.expectEqual(3, backend.total);
}
