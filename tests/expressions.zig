const std = @import("std");
const ex = @import("zigexec");
const t = std.testing;
const support = @import("support.zig");

const Add = struct {
    offset: i64,
    pub fn call(self: @This(), value: i64) i64 {
        return self.offset + value;
    }
};
const Duplicate = struct {
    pub fn call(_: @This(), value: anytype) ex.Just(.{@TypeOf(value)}) {
        return ex.just(value * 2);
    }
};

test "scoped expression infers the entire graph and captures runtime state" {
    var offset: i64 = 3;
    const body = ex.upstream().letValue(Duplicate, .{}).then(Add, .{offset});
    offset = 100;
    const task = ex.just(20).letValue(body, .{});
    try t.expectEqual(43, (try task.syncWait(.{ .allocator = std.testing.allocator })).?[0]);
    try t.expectEqual(ex.Values(.{i64}), @TypeOf(task).Values);
    try t.expectEqual(@TypeOf(task), ex.LetValue(ex.Just(.{i64}), @TypeOf(body)));
    // A body can be reused for different upstream types without repeating it.
    try t.expectEqual(13, (try ex.just(@as(u16, 5)).letValue(body, .{}).syncWait(.{ .allocator = std.testing.allocator })).?[0]);
}

test "nearest letValue wins and outer continuation sees nested completion" {
    const body = ex.upstream()
        .then(Add, .{1})
        .letValue(ex.upstream().letValue(Duplicate, .{}).then(Add, .{3}), .{})
        .then(Add, .{5});
    // ((10 + 1) * 2 + 3) + 5, not (10 * 2 + 3) + 5.
    try t.expectEqual(30, (try ex.just(10).letValue(body, .{}).syncWait(.{ .allocator = std.testing.allocator })).?[0]);
    try t.expectEqual(10, (try ex.just(10).letValue(ex.upstream(), .{}).syncWait(.{ .allocator = std.testing.allocator })).?[0]);
}

test "body construction and connect do not execute factories and operations are reusable" {
    const Factory = struct {
        calls: *usize,
        counter: i64,
        pub fn call(self: *@This(), value: i64) ex.Just(.{i64}) {
            self.calls.* += 1;
            self.counter += 1;
            return ex.just(value + self.counter);
        }
    };
    var calls: usize = 0;
    const task = ex.just(40).letValue(ex.upstream().letValue(Factory, .{ &calls, 1 }), .{});
    var capture: support.IntCapture = .{};
    var operation: ex.Connection(@TypeOf(task), @TypeOf(&capture)) = undefined;
    ex.connectInto(&operation, task, &capture);
    try t.expectEqual(0, calls);
    operation.start();
    try t.expectEqual(42, capture.values.?[0]);
    try t.expectEqual(42, (try task.syncWait(.{ .allocator = std.testing.allocator })).?[0]);
    try t.expectEqual(2, calls);
}

test "capture initialization supports positional named and defaulted fields" {
    const WithDefault = struct {
        offset: i64 = 2,
        pub fn call(self: *const @This(), n: i64) i64 {
            return self.offset + n;
        }
    };
    try t.expectEqual(42, (try ex.just(40).then(WithDefault, .{}).syncWait(.{ .allocator = std.testing.allocator })).?[0]);
    try t.expectEqual(43, (try ex.just(40).then(WithDefault, .{3}).syncWait(.{ .allocator = std.testing.allocator })).?[0]);
    try t.expectEqual(44, (try ex.just(40).then(WithDefault, .{ .offset = 4 }).syncWait(.{ .allocator = std.testing.allocator })).?[0]);
}

test "scoped inputs support empty and multiple completion values and generic callTuple" {
    const Sum = struct {
        pub fn callTuple(_: @This(), args: anytype) i64 {
            var n: i64 = 0;
            inline for (args) |arg| n += arg;
            return n;
        }
    };
    const body = ex.upstream().then(Sum, .{});
    try t.expectEqual(0, (try ex.just(.{}).letValue(body, .{}).syncWait(.{ .allocator = std.testing.allocator })).?[0]);
    try t.expectEqual(42, (try ex.just(.{ 12, 30 }).letValue(body, .{}).syncWait(.{ .allocator = std.testing.allocator })).?[0]);
    const Triple = struct {
        pub fn call(_: @This(), n: i64) ex.Just(.{ i64, i64, i64 }) {
            return ex.just(.{ n, n, n });
        }
    };
    try t.expectEqual(42, (try ex.just(14).letValue(ex.upstream().letValue(Triple, .{}).then(Sum, .{}), .{}).syncWait(.{ .allocator = std.testing.allocator })).?[0]);
}

test "scope bypasses its body on error and stopped; factory failures use error channel" {
    const Never = struct {
        pub fn call(_: @This(), n: i64) ex.Just(.{i64}) {
            _ = n;
            @panic("body must not run");
        }
    };
    const Fail = struct {
        pub fn call(_: @This(), _: i64) error{FactoryFailed}!ex.Just(.{i64}) {
            return error.FactoryFailed;
        }
    };
    const body = ex.upstream().letValue(Never, .{});
    try t.expectError(error.Upstream, ex.justError(ex.Values(.{i64}), error.Upstream).letValue(body, .{}).syncWait(.{ .allocator = std.testing.allocator }));
    try t.expectEqual(null, try ex.justStopped(ex.Values(.{i64})).letValue(body, .{}).syncWait(.{ .allocator = std.testing.allocator }));
    try t.expectError(error.FactoryFailed, ex.just(1).letValue(ex.upstream().letValue(Fail, .{}).letValue(Never, .{}), .{}).syncWait(.{ .allocator = std.testing.allocator }));
}

test "slice values keep the allocation address across asynchronous composition" {
    const Forward = struct {
        scheduler: ex.RunLoop.Scheduler,
        seen: *?[]u8,
        pub fn call(self: @This(), buffer: []u8) ex.Just(.{[]u8}).StartsOn(ex.RunLoop.Scheduler) {
            self.seen.* = buffer;
            buffer[0] += 1;
            return ex.just(buffer).startsOn(self.scheduler);
        }
    };
    const Read = struct {
        pub fn call(_: @This(), buffer: []u8) i64 {
            return @as(i64, buffer[0]) + buffer[1] + buffer[2];
        }
    };
    const buffer = try t.allocator.dupe(u8, &.{ 10, 20, 11 });
    defer t.allocator.free(buffer);
    var loop: ex.RunLoop = .{};
    var seen: ?[]u8 = null;
    const task = ex.just(buffer).letValue(ex.upstream().letValue(Forward, .{ loop.getScheduler(), &seen }).then(Read, .{}), .{});
    var capture: support.IntCapture = .{};
    var operation: ex.Connection(@TypeOf(task), @TypeOf(&capture)) = undefined;
    ex.connectInto(&operation, task, &capture);
    operation.start();
    try t.expectEqual(0, capture.completions);
    try t.expectEqual(buffer.ptr, seen.?.ptr);
    try t.expectEqual(11, buffer[0]);
    loop.finish();
    loop.run();
    try t.expectEqual(42, capture.values.?[0]);
}

test "factory pointer self lends captured storage until asynchronous completion" {
    const Factory = struct {
        scheduler: ex.RunLoop.Scheduler,
        number: i64,
        seen: *?*i64,
        pub fn call(self: *@This()) ex.Just(.{*i64}).StartsOn(ex.RunLoop.Scheduler) {
            self.number += 2;
            self.seen.* = &self.number;
            return ex.just(.{&self.number}).startsOn(self.scheduler);
        }
    };
    const Read = struct {
        pub fn call(_: @This(), value: *i64) i64 {
            return value.*;
        }
    };
    var loop: ex.RunLoop = .{};
    var seen: ?*i64 = null;
    const task = ex.just(.{}).letValue(ex.upstream().letValue(Factory, .{ loop.getScheduler(), 40, &seen }).then(Read, .{}), .{});
    var capture: support.IntCapture = .{};
    var operation: ex.Connection(@TypeOf(task), @TypeOf(&capture)) = undefined;
    ex.connectInto(&operation, task, &capture);
    operation.start();
    try t.expectEqual(0, capture.completions);
    try t.expect(@intFromPtr(seen.?) >= @intFromPtr(&operation));
    try t.expect(@intFromPtr(seen.?) + @sizeOf(i64) <= @intFromPtr(&operation) + @sizeOf(@TypeOf(operation)));
    loop.finish();
    loop.run();
    try t.expectEqual(42, capture.values.?[0]);
}

test "upstream operation storage stays alive through scoped continuation" {
    const Source = struct {
        pub const Values = ex.Values(.{[]const u8});
        pub fn Operation(comptime R: type) type {
            return struct {
                receiver: ex.TypedReceiver(Values, R),
                output: Values = undefined,
                buffer: [3]u8 = .{ 20, 21, 1 },
                pub fn start(self: *@This()) void {
                    self.output = .{&self.buffer};
                    self.receiver.setValue(&self.output);
                }
            };
        }
        pub fn connectInto(_: @This(), out: anytype, receiver: anytype) void {
            out.* = .{ .receiver = .init(receiver) };
        }
    };
    const Sum = struct {
        pub fn call(_: @This(), bytes: []const u8) i64 {
            var n: i64 = 0;
            for (bytes) |b| n += b;
            return n;
        }
    };
    var loop: ex.RunLoop = .{};
    const task = ex.asSender(Source{}).letValue(ex.upstream().continuesOn(loop.getScheduler()).then(Sum, .{}), .{});
    var capture: support.IntCapture = .{};
    var operation: ex.Connection(@TypeOf(task), @TypeOf(&capture)) = undefined;
    ex.connectInto(&operation, task, &capture);
    operation.start();
    try t.expectEqual(0, capture.completions);
    loop.finish();
    loop.run();
    try t.expectEqual(42, capture.values.?[0]);
}

test "expression recovery and bulk preserve error stopped and environment semantics" {
    const Fail = struct {
        pub fn call(_: @This(), _: i64) error{Failed}!i64 {
            return error.Failed;
        }
    };
    const Recover = struct {
        pub fn call(_: @This(), _: anyerror) i64 {
            return 42;
        }
    };
    const Inc = struct {
        count: *usize,
        pub fn call(self: *@This(), _: usize, _: i64) void {
            self.count.* += 1;
        }
    };
    var count: usize = 0;
    const body = ex.upstream().then(Fail, .{}).uponError(Recover, .{}).bulk(3, Inc, .{&count});
    try t.expectEqual(42, (try ex.just(1).letValue(body, .{}).syncWait(.{ .allocator = std.testing.allocator })).?[0]);
    try t.expectEqual(3, count);
    var source: ex.StopSource = .{};
    defer source.deinit();
    _ = source.requestStop();
    try t.expectEqual(null, try ex.just(1).letValue(body, .{}).withStopToken(source.token()).syncWait(.{ .allocator = std.testing.allocator }));
}

test "scoped connection may be destroyed in completion" {
    const task = ex.just(20).letValue(ex.upstream().letValue(Duplicate, .{}).then(Add, .{2}), .{});
    const Destroy = struct {
        const Op = ex.Connection(@TypeOf(task), *@This());
        op: *Op,
        called: bool = false,
        pub fn getEnv(_: *@This()) ex.Env {
            return .{ .allocator = std.testing.allocator };
        }
        pub fn setValue(self: *@This(), values: *const ex.Values(.{i64})) void {
            defer self.completeOwnership();
            std.debug.assert(values.*[0] == 42);
        }
        fn completeOwnership(self: *@This()) void {
            t.allocator.destroy(self.op);
            self.called = true;
        }
        pub fn setError(self: *@This(), _: anyerror) void {
            defer self.completeOwnership();
            @panic("unexpected error");
        }
        pub fn setStopped(self: *@This()) void {
            defer self.completeOwnership();
            @panic("unexpected stopped");
        }
    };
    const Op = Destroy.Op;
    const op = try t.allocator.create(Op);
    var receiver: Destroy = .{ .op = op };
    ex.connectInto(op, task, &receiver);
    op.start();
    try t.expect(receiver.called);
}

test "generic comptime functions specialize without runtime function pointers" {
    const Generic = struct {
        fn twice(n: anytype) @TypeOf(n) {
            return n * 2;
        }
    };
    const task = ex.just(@as(u16, 21)).letValue(ex.upstream().then(ex.Fn(Generic.twice), .{}), .{});
    try t.expectEqual(u16, ex.meta.ValueOf(@TypeOf(task)));
    try t.expectEqual(42, (try task.syncWait(.{ .allocator = std.testing.allocator })).?[0]);
}

test "letValue accepts a concrete sender with its own inputs" {
    const child = ex.just(@as(u16, 7));
    const task = ex.just(.{ 10, true }).letValue(child, .{});
    try t.expectEqual(ex.Values(.{u16}), @TypeOf(task).Values);
    try t.expectEqual(@TypeOf(task), ex.LetValue(ex.Just(.{ i64, bool }), @TypeOf(child)));
    try t.expectEqual(@TypeOf(task), ex.Just(.{ i64, bool }).LetValue(@TypeOf(child)));
    try t.expectEqual(@TypeOf(task), @TypeOf(ex.letValue(ex.just(.{ 10, true }), child, .{})));
    try t.expectEqual(7, (try task.syncWait(.{ .allocator = t.allocator })).?[0]);
    const body = ex.upstream().letValue(ex.just(40), .{}).then(Add, .{2});
    try t.expectEqual(42, (try ex.just(.{}).letValue(body, .{}).syncWait(.{ .allocator = t.allocator })).?[0]);
}

test "concrete async continuation forwards its environment and completion channels" {
    const Check = struct {
        pub fn call(_: @This(), env: ex.Env) !i64 {
            const allocator = try env.getAllocator();
            try t.expectEqual(t.allocator.vtable, allocator.vtable);
            try t.expectEqual(t.allocator.ptr, allocator.ptr);
            try t.expect(env.stop_token.stopPossible());
            return 42;
        }
    };
    const pool = try ex.ThreadPool.init(t.allocator, 1);
    defer pool.deinit();
    var stop: ex.StopSource = .{};
    defer stop.deinit();
    const env: ex.Env = .{ .allocator = t.allocator, .stop_token = stop.token() };
    const child = ex.readEnv().then(Check, .{}).startsOn(pool.getScheduler());
    try t.expectEqual(42, (try ex.just(123).letValue(child, .{}).syncWait(env)).?[0]);
    const failed = ex.justError(ex.Values(.{i64}), error.ChildFailed).startsOn(pool.getScheduler());
    try t.expectError(error.ChildFailed, ex.just(.{}).letValue(failed, .{}).syncWait(env));
    const stopped = ex.justStopped(ex.Values(.{i64})).startsOn(pool.getScheduler());
    try t.expectEqual(null, try ex.just(.{}).letValue(stopped, .{}).syncWait(env));
}

test "concrete continuation is started lazily and skipped on upstream error or stop" {
    const Count = struct {
        calls: *usize,
        pub fn call(self: @This(), n: i64) i64 {
            self.calls.* += 1;
            return n;
        }
    };
    var calls: usize = 0;
    const child = ex.just(42).then(Count, .{&calls});
    const task = ex.just(.{}).letValue(child, .{});
    var capture: support.IntCapture = .{};
    var operation: ex.Connection(@TypeOf(task), @TypeOf(&capture)) = undefined;
    ex.connectInto(&operation, task, &capture);
    try t.expectEqual(0, calls);
    try t.expectError(error.Upstream, ex.justError(ex.Values(.{}), error.Upstream).letValue(child, .{}).syncWait(.{ .allocator = t.allocator }));
    try t.expectEqual(null, try ex.justStopped(ex.Values(.{})).letValue(child, .{}).syncWait(.{ .allocator = t.allocator }));
    try t.expectEqual(0, calls);
    operation.start();
    try t.expectEqual(1, calls);
    try t.expectEqual(42, capture.values.?[0]);
}
