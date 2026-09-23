const std = @import("std");
const ex = @import("zigexec");
const t = std.testing;
const MockIo = @import("io.zig").Backend;

fn double(n: i64) i64 {
    return n * 2;
}
fn makeNumber(n: i64) ex.Just(.{i64}) {
    return ex.just(.{n});
}
fn makeWork(n: i64) ex.Just(.{i64}).Then(ex.Fn(double)).StartsOn(ex.InlineScheduler) {
    return ex.just(.{n}).then(ex.Fn(double), .{}).startsOn(ex.InlineScheduler{});
}

test "named constructors are exact return types and support type-level composition" {
    const number: ex.Just(.{i64}) = makeNumber(21);
    const transformed: ex.Then(ex.Just(.{i64}), ex.Fn(double)) = number.then(ex.Fn(double), .{});
    try t.expectEqual(42, (try transformed.syncWait(.{ .allocator = std.testing.allocator })).?[0]);
    try t.expectEqual(42, (try makeWork(21).syncWait(.{ .allocator = std.testing.allocator })).?[0]);
    const empty: ex.Just(.{}) = ex.just(.{});
    const joined: ex.WhenAll(.{ @TypeOf(transformed), @TypeOf(empty) }) = ex.whenAll(.{ transformed, empty });
    try t.expectEqual(42, (try joined.syncWait(.{ .allocator = std.testing.allocator })).?[0]);
    const moved: ex.ContinuesOn(@TypeOf(joined), ex.InlineScheduler) = joined.continuesOn(ex.InlineScheduler{});
    const cancellable: @TypeOf(moved).WithStopToken() = moved.withStopToken(.{});
    try t.expectEqual(42, (try cancellable.syncWait(.{ .allocator = std.testing.allocator })).?[0]);
    const nothing: ex.WhenAll(.{}) = ex.whenAll(.{});
    try t.expect((try nothing.syncWait(.{ .allocator = std.testing.allocator })) != null);
}

test "scheduler entry points name the same types" {
    const scheduler: ex.InlineScheduler = .{};
    const scheduled: ex.Schedule(ex.InlineScheduler) = scheduler.schedule();
    try t.expectEqual(@TypeOf(scheduled), @TypeOf(ex.schedule(scheduler)));
    try t.expectEqual(@TypeOf(scheduled), @TypeOf(ex.asSender(scheduled)));
    try t.expectEqual(@TypeOf(scheduled), ex.Sender(@TypeOf(scheduled)));
    var loop: ex.RunLoop = .{};
    const queue: ex.RunLoop.Scheduler = loop.getScheduler();
    const queued: ex.Schedule(ex.RunLoop.Scheduler) = queue.schedule();
    try t.expectEqual(@TypeOf(queued), @TypeOf(ex.schedule(queue)));
}

test "typed errors stopped and recovery constructors" {
    const Recover = struct {
        fn value(_: anyerror) i64 {
            return 21;
        }
        fn sender(_: anyerror) ex.Just(.{i64}) {
            return ex.just(.{21});
        }
        fn stopped() i64 {
            return 7;
        }
        fn stoppedSender() ex.Just(.{i64}) {
            return ex.just(.{7});
        }
    };
    const failed: ex.JustError(.{i64}) = ex.justError(ex.Values(.{i64}), error.Broken);
    const recovered: ex.UponError(@TypeOf(failed), ex.Fn(Recover.value)) = failed.uponError(ex.Fn(Recover.value), .{});
    try t.expectEqual(21, (try recovered.syncWait(.{ .allocator = std.testing.allocator })).?[0]);
    const continued: ex.LetError(@TypeOf(failed), ex.Fn(Recover.sender)) = failed.letError(ex.Fn(Recover.sender), .{});
    try t.expectEqual(21, (try continued.syncWait(.{ .allocator = std.testing.allocator })).?[0]);
    const stopped: ex.JustStopped(.{i64}) = ex.justStopped(ex.Values(.{i64}));
    const resumed: ex.UponStopped(@TypeOf(stopped), ex.Fn(Recover.stopped)) = stopped.uponStopped(ex.Fn(Recover.stopped), .{});
    try t.expectEqual(7, (try resumed.syncWait(.{ .allocator = std.testing.allocator })).?[0]);
    const resumed_sender: ex.LetStopped(@TypeOf(stopped), ex.Fn(Recover.stoppedSender)) = stopped.letStopped(ex.Fn(Recover.stoppedSender), .{});
    try t.expectEqual(7, (try resumed_sender.syncWait(.{ .allocator = std.testing.allocator })).?[0]);
    const env: ex.ReadEnv = ex.readEnv();
    try t.expect(!(try env.syncWait(.{ .allocator = std.testing.allocator })).?[0].stop_token.stopPossible());
}

test "generic callable structs infer their return type from upstream values" {
    const Twice = struct {
        pub fn call(_: @This(), value: anytype) @TypeOf(value) {
            return value * 2;
        }
    };
    const small = ex.just(.{@as(u16, 21)}).then(Twice, .{});
    const big = ex.just(.{@as(i64, 21)}).then(Twice, .{});
    try t.expectEqual(u16, ex.meta.ValueOf(@TypeOf(small)));
    try t.expectEqual(i64, ex.meta.ValueOf(@TypeOf(big)));
    try t.expectEqual(42, (try small.syncWait(.{ .allocator = std.testing.allocator })).?[0]);
    try t.expectEqual(42, (try big.syncWait(.{ .allocator = std.testing.allocator })).?[0]);
    try t.expectEqual(u16, ex.meta.CallResult(Twice, ex.Values(.{u16})));
}

test "generic letValue infers a sender and its new value tuple" {
    const Duplicate = struct {
        pub fn call(_: @This(), value: anytype) ex.Just(.{ @TypeOf(value), bool }) {
            return ex.just(.{ value, true });
        }
    };
    const work: ex.LetValue(ex.Just(.{u16}), Duplicate) = ex.just(.{@as(u16, 42)}).letValue(Duplicate, .{});
    const result = (try work.syncWait(.{ .allocator = std.testing.allocator })).?;
    try t.expectEqual(ex.Values(.{ u16, bool }), @TypeOf(result));
    try t.expectEqual(42, result[0]);
    try t.expect(result[1]);
}

test "bind preserves a generic function identity and runtime captures" {
    const Functions = struct {
        fn add(base: i64, value: i64) i64 {
            return base + value;
        }
        fn multiply(factor: *i64, value: anytype) @TypeOf(value) {
            return value * @as(@TypeOf(value), @intCast(factor.*));
        }
        fn duplicate(value: anytype) ex.Just(.{ @TypeOf(value), @TypeOf(value) }) {
            return ex.just(.{ value, value });
        }
    };
    try t.expectEqual(42, (try ex.just(.{40}).then(@TypeOf(ex.bind(Functions.add, .{2})), ex.bind(Functions.add, .{2})).syncWait(.{ .allocator = std.testing.allocator })).?[0]);
    var factor: i64 = 2;
    const callback: ex.Bind(Functions.multiply, .{*i64}) = ex.bind(Functions.multiply, .{&factor});
    const work = ex.just(.{@as(i32, 14)}).then(@TypeOf(callback), callback).letValue(@TypeOf(ex.bind(Functions.duplicate, .{})), ex.bind(Functions.duplicate, .{}));
    factor = 3;
    const result = (try work.syncWait(.{ .allocator = std.testing.allocator })).?;
    try t.expectEqual(ex.Values(.{ i32, i32 }), @TypeOf(result));
    try t.expectEqual(42, result[0]);
    try t.expectEqual(42, result[1]);
}

test "generic callbacks retain error unions and support bulk argument inference" {
    const Functions = struct {
        fn checked(value: anytype) error{Zero}!@TypeOf(value) {
            if (value == 0) return error.Zero;
            return value;
        }
        fn factory(value: anytype) error{Zero}!ex.Just(.{@TypeOf(value)}) {
            if (value == 0) return error.Zero;
            return ex.just(.{value});
        }
        fn fill(buffer: anytype, index: usize, value: anytype) void {
            buffer[index] = value;
        }
    };
    try t.expectError(error.Zero, ex.just(.{0}).then(@TypeOf(ex.bind(Functions.checked, .{})), ex.bind(Functions.checked, .{})).syncWait(.{ .allocator = std.testing.allocator }));
    try t.expectError(error.Zero, ex.just(.{0}).letValue(@TypeOf(ex.bind(Functions.factory, .{})), ex.bind(Functions.factory, .{})).syncWait(.{ .allocator = std.testing.allocator }));
    var buffer: [3]u8 = undefined;
    const fill = ex.bind(Functions.fill, .{&buffer});
    const work: ex.Bulk(ex.Just(.{u8}), @TypeOf(fill)) = ex.just(.{@as(u8, 42)}).bulk(3, @TypeOf(fill), fill);
    _ = try work.syncWait(.{ .allocator = std.testing.allocator });
    try t.expectEqualSlices(u8, &.{ 42, 42, 42 }, &buffer);
}

test "I/O namespace specializes both type and value APIs for a backend" {
    const Io = ex.io.For(*MockIo);
    var context: MockIo = .{};
    var buffer: [4]u8 = undefined;
    const ReadBack = struct {
        context: *MockIo,
        buffer: []u8,
        pub fn call(self: @This(), _: usize) Io.ReadSome {
            return Io.readSome(self.context, 1, self.buffer, 0);
        }
    };
    const written: Io.WriteSome = Io.writeSome(&context, 1, "abc", 0);
    const pipeline = written.letValue(ReadBack, .{ .context = &context, .buffer = &buffer });
    try t.expectEqual(3, (try pipeline.syncWait(.{ .allocator = std.testing.allocator })).?[0]);
    try t.expectEqualStrings("abc", buffer[0..3]);
    try t.expectEqual(ex.io.ReadSome(*MockIo), Io.ReadSome);
    try t.expectEqual(Io.ReadSome, ex.meta.ReturnOf(Io.readSome, .{ *MockIo, i32, []u8, u64 }));
    try t.expectEqual(Io.ReadSome, ex.meta.ReturnOf(ex.io.readSome, .{ *MockIo, i32, []u8, u64 }));
}

test "I/O named types match every constructor without running I/O" {
    const Io = ex.io.For(*ex.IoUring);
    const M = ex.meta;
    try t.expectEqual(Io.ReadSome, M.ReturnOf(ex.io.readSome, .{ *ex.IoUring, i32, []u8, u64 }));
    try t.expectEqual(Io.WriteSome, M.ReturnOf(ex.io.writeSome, .{ *ex.IoUring, i32, []const u8, u64 }));
    try t.expectEqual(Io.Recv, M.ReturnOf(ex.io.recv, .{ *ex.IoUring, i32, []u8, u32 }));
    try t.expectEqual(Io.Send, M.ReturnOf(ex.io.send, .{ *ex.IoUring, i32, []const u8, u32 }));
    try t.expectEqual(Io.OpenAt, M.ReturnOf(ex.io.openAt, .{ *ex.IoUring, i32, [:0]const u8, u32, u32 }));
    try t.expectEqual(Io.Close, M.ReturnOf(ex.io.close, .{ *ex.IoUring, i32 }));
    try t.expectEqual(Io.Fsync, M.ReturnOf(ex.io.fsync, .{ *ex.IoUring, i32 }));
    try t.expectEqual(Io.SleepFor, M.ReturnOf(ex.io.sleepFor, .{ *ex.IoUring, u64 }));
    try t.expectEqual(Io.Accept, M.ReturnOf(ex.io.accept, .{ *ex.IoUring, i32, u32 }));
    try t.expectEqual(Io.Connect, M.ReturnOf(ex.io.connect, .{ *ex.IoUring, i32, *const std.posix.sockaddr, std.posix.socklen_t }));
    try t.expectEqual(Io.Schedule, ex.Schedule(ex.IoUring.Scheduler));
}

test "meta helpers describe operations and do not execute factories" {
    const Factory = struct {
        fn forbidden(_: i64) ex.Just(.{i64}) {
            @panic("type query executed a function");
        }
    };
    const S = ex.meta.ReturnOf(Factory.forbidden, .{i64});
    try t.expectEqual(ex.Just(.{i64}), S);
    try t.expectEqual(ex.Values(.{i64}), ex.meta.ValuesOf(S));
    try t.expectEqual(S.Operation(ex.Receiver(S.Values)), ex.meta.OperationOf(S, ex.Receiver(S.Values)));
    const result: ex.meta.WaitResult(S) = ex.just(.{42}).syncWait(.{ .allocator = std.testing.allocator });
    try t.expectEqual(42, (try result).?[0]);
}

test "tuple callbacks infer arbitrary upstream arity including an empty tuple" {
    const Sum = struct {
        pub fn callTuple(_: @This(), args: anytype) i64 {
            var sum: i64 = 0;
            inline for (args) |value| sum += value;
            return sum;
        }
    };
    try t.expectEqual(0, (try ex.just(.{}).then(Sum, .{}).syncWait(.{ .allocator = std.testing.allocator })).?[0]);
    try t.expectEqual(42, (try ex.just(.{ 20, 21, 1 }).then(Sum, .{}).syncWait(.{ .allocator = std.testing.allocator })).?[0]);
}
