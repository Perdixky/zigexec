const std = @import("std");
const ex = @import("zigexec");
const t = std.testing;

fn expectAllocator(expected: std.mem.Allocator, actual: std.mem.Allocator) !void {
    try t.expectEqual(expected.vtable, actual.vtable);
    // Stateless page_allocator leaves ptr undefined; it is not an identity.
    if (expected.vtable != std.heap.page_allocator.vtable)
        try t.expectEqual(expected.ptr, actual.ptr);
}

const Query = struct {
    pub fn call(_: @This()) ex.ReadAllocator {
        return ex.readAllocator();
    }
};

// A custom allocating sender, exercising the same receiver API available to
// library algorithms. Every completion occurs after temporary storage is freed.
const Allocating = struct {
    outcome: enum { value, err, stopped } = .value,
    pub const Values = ex.Values(.{usize});
    pub fn Operation(comptime R: type) type {
        return struct {
            outcome: @FieldType(Allocating, "outcome"),
            receiver: ex.TypedReceiver(Values, R),
            output: Values = undefined,
            fn work(allocator: std.mem.Allocator) !usize {
                const first = try allocator.alloc(u8, 32);
                defer allocator.free(first);
                const second = try allocator.alloc(u8, 64);
                defer allocator.free(second);
                @memset(first, 1);
                @memset(second, 2);
                return first.len + second.len;
            }
            pub fn start(self: *@This()) void {
                const allocator = self.receiver.getEnv().getAllocator() catch |err| return self.receiver.setError(err);
                const count = work(allocator) catch |err| return self.receiver.setError(err);
                self.output = .{count};
                switch (self.outcome) {
                    .value => self.receiver.setValue(&self.output),
                    .err => self.receiver.setError(error.AfterAllocation),
                    .stopped => self.receiver.setStopped(),
                }
            }
        };
    }
    pub fn connectInto(self: @This(), out: anytype, receiver: anytype) void {
        out.* = .{ .outcome = self.outcome, .receiver = .init(receiver) };
    }
};

test "allocator query is resolved from the explicit environment per connection" {
    const sender: ex.ReadAllocator = ex.readAllocator();
    try expectAllocator(std.heap.page_allocator, (try sender.syncWait(.{ .allocator = std.heap.page_allocator })).?[0]);
    try expectAllocator(t.allocator, (try sender.syncWait(.{ .allocator = t.allocator })).?[0]);
    try expectAllocator(t.failing_allocator, (try ex.syncWait(sender, .{ .allocator = t.failing_allocator })).?[0]);
}

test "allocator crosses nested scopes factories schedules whenAll and stop overrides" {
    const pool = try ex.ThreadPool.init(t.allocator, 2);
    defer pool.deinit();
    var stop: ex.StopSource = .{};
    defer stop.deinit();
    const branch = ex.just(.{}).letValue(ex.upstream().letValue(ex.upstream().letValue(Query, .{}), .{}).continuesOn(pool.getScheduler()), .{}).withStopToken(stop.token()).startsOn(pool.getScheduler());
    const values = (try ex.whenAll(.{ branch, ex.readAllocator() }).syncWait(.{ .allocator = t.allocator })).?;
    try expectAllocator(t.allocator, values[0]);
    try expectAllocator(t.allocator, values[1]);
}

test "stop override preserves allocator and still observes parent cancellation" {
    var parent: ex.StopSource = .{};
    defer parent.deinit();
    _ = parent.requestStop();
    var extra: ex.StopSource = .{};
    defer extra.deinit();
    const Check = struct {
        pub fn call(_: @This(), current: ex.Env) !bool {
            try expectAllocator(t.allocator, try current.getAllocator());
            return current.stop_token.stopRequested();
        }
    };
    try t.expect((try ex.readEnv().withStopToken(extra.token()).then(Check, .{}).syncWait(.{
        .allocator = t.allocator,
        .stop_token = parent.token(),
    })).?[0]);
}

test "custom terminal receiver supplies allocator without syncWait" {
    const Capture = struct {
        result: ?usize = null,
        pub fn getEnv(_: *@This()) ex.Env {
            return .{ .allocator = t.allocator };
        }
        pub fn setValue(self: *@This(), value: *const Allocating.Values) void {
            self.result = value.*[0];
        }
        pub fn setError(_: *@This(), _: anyerror) void {
            @panic("unexpected failure");
        }
        pub fn setStopped(_: *@This()) void {
            @panic("unexpected stop");
        }
    };
    var capture: Capture = .{};
    var operation: ex.Connection(@TypeOf(Allocating{}), @TypeOf(&capture)) = undefined;
    ex.connectInto(&operation, Allocating{}, &capture);
    try t.expectEqual(null, capture.result);
    operation.start();
    try t.expectEqual(96, capture.result.?);
}

test "execution allocation failures propagate and temporary storage is freed on all channels" {
    const Run = struct {
        fn check(allocator: std.mem.Allocator) !void {
            try t.expectEqual(96, (try ex.asSender(Allocating{}).syncWait(.{ .allocator = allocator })).?[0]);
        }
    };
    try t.checkAllAllocationFailures(t.allocator, Run.check, .{});
    try t.expectError(error.OutOfMemory, ex.asSender(Allocating{}).syncWait(.{ .allocator = t.failing_allocator }));
    try t.expectError(error.AfterAllocation, ex.asSender(Allocating{ .outcome = .err }).syncWait(.{ .allocator = t.allocator }));
    try t.expectEqual(null, try ex.asSender(Allocating{ .outcome = .stopped }).syncWait(.{ .allocator = t.allocator }));
}

test "allocated results remain owned by the caller after syncWait returns" {
    const MakeBuffer = struct {
        count: usize,
        pub fn call(self: @This(), allocator: std.mem.Allocator) ![]u8 {
            const bytes = try allocator.alloc(u8, self.count);
            @memset(bytes, 42);
            return bytes;
        }
    };
    const task = ex.readAllocator().then(MakeBuffer, .{8});
    const bytes = (try task.syncWait(.{ .allocator = t.allocator })).?[0];
    defer t.allocator.free(bytes);
    try t.expectEqualSlices(u8, &@as([8]u8, @splat(42)), bytes);
    try t.expectError(error.OutOfMemory, task.syncWait(.{ .allocator = t.failing_allocator }));
}

test "shared execution uses its owner allocator instead of a subscriber allocator" {
    var shared = try ex.readAllocator().split(t.allocator);
    defer shared.deinit();
    try expectAllocator(t.allocator, (try shared.sender().syncWait(.{})).?[0]);
    try expectAllocator(t.allocator, (try shared.sender().syncWait(.{ .allocator = t.failing_allocator })).?[0]);
    try expectAllocator(t.allocator, (try shared.sender().syncWait(.{ .allocator = std.heap.page_allocator })).?[0]);
    var work = try ex.asSender(Allocating{}).split(t.allocator);
    defer work.deinit();
    try t.expectEqual(96, (try work.sender().syncWait(.{ .allocator = t.failing_allocator })).?[0]);
}

test "empty environments execute synchronous and scheduled graphs without an allocator" {
    try t.expectEqual(42, (try ex.just(42).syncWait(.{})).?[0]);
    const pool = try ex.ThreadPool.init(t.allocator, 2);
    defer pool.deinit();
    var stop: ex.StopSource = .{};
    defer stop.deinit();
    const Check = struct {
        pub fn call(_: @This(), env: ex.Env) !bool {
            try t.expectEqual(null, env.allocator);
            try t.expect(env.stop_token.stopPossible());
            try t.expectError(error.MissingAllocator, env.getAllocator());
            return true;
        }
    };
    const task = ex.just(.{}).letValue(ex.upstream().letValue(ex.readEnv(), .{}), .{})
        .withStopToken(stop.token()).continuesOn(pool.getScheduler())
        .then(Check, .{}).repeatUntil().startsOn(pool.getScheduler());
    const result = (try ex.whenAll(.{ task, ex.just(42) }).syncWait(.{})).?;
    try t.expectEqual(42, result[0]);
}

test "missing allocator fails at query time and can be recovered" {
    const sender = ex.readAllocator();
    try t.expectError(error.MissingAllocator, sender.syncWait(.{}));
    try t.expectError(error.MissingAllocator, sender.syncWait(.{ .allocator = null }));
    try t.expectError(error.MissingAllocator, ex.asSender(Allocating{}).syncWait(.{}));
    const pool = try ex.ThreadPool.init(t.allocator, 1);
    defer pool.deinit();
    const task = ex.just(.{}).letValue(ex.upstream().letValue(Query, .{}), .{}).startsOn(pool.getScheduler());
    try t.expectError(error.MissingAllocator, task.syncWait(.{}));
    // No allocator is queried if the continuation is skipped.
    try t.expectEqual(null, try ex.justStopped(ex.Values(.{})).letValue(Query, .{}).syncWait(.{}));
    try t.expectError(error.Upstream, ex.justError(ex.Values(.{}), error.Upstream).letValue(Query, .{}).syncWait(.{}));
    const Recover = struct {
        pub fn call(_: @This(), err: anyerror) !std.mem.Allocator {
            try t.expectEqual(error.MissingAllocator, err);
            return t.allocator;
        }
    };
    try expectAllocator(t.allocator, (try sender.uponError(Recover, .{}).syncWait(.{})).?[0]);
    try expectAllocator(t.allocator, (try sender.syncWait(.{ .allocator = t.allocator })).?[0]);
}
