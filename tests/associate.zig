const std = @import("std");
const ex = @import("zigexec");
const t = std.testing;
const Empty = ex.Values(.{});
const inline_scheduler: ex.InlineScheduler = .{};
const Capture = struct {
    finished: bool = false,
    pub fn getEnv(_: *@This()) ex.Env {
        return .{ .start_scheduler = ex.StartScheduler.init(&inline_scheduler) };
    }
    pub fn setValue(_: *@This(), _: *const Empty) void {}
    pub fn setError(_: *@This(), _: anyerror) void {
        @panic("unexpected error");
    }
    pub fn setStopped(_: *@This()) void {
        @panic("unexpected stop");
    }
    pub fn setFinished(self: *@This()) void {
        self.finished = true;
    }
};

test "associate is eager association lazy execution and allocation free" {
    var scope: ex.SimpleCountingScope = .{};
    defer scope.deinit();
    var count: usize = 0;
    const Work = struct {
        count: *usize,
        pub fn call(self: @This()) i64 {
            self.count.* += 1;
            return 42;
        }
    };
    var owner = ex.associate(ex.just(.{}).then(Work, .{&count}), scope.getToken());
    defer owner.deinit();
    try t.expect(owner.isEngaged());
    try t.expectEqual(0, count);
    var clone = owner.clone();
    clone.deinit();
    try t.expectEqual(42, (try owner.sender().syncWait(.{})).?[0]);
    try t.expectEqual(42, (try owner.sender().syncWait(.{})).?[0]);
    try t.expectEqual(2, count);
    var capture: Capture = .{};
    var join = ex.connect(scope.join(), &capture);
    join.start();
    try t.expect(!capture.finished); // Sender owner still holds an association.
    owner.deinit();
    try t.expect(capture.finished);
}

test "associate refusal stops without executing and transfer survives close" {
    var scope: ex.CountingScope = .{};
    defer scope.deinit();
    var owner = ex.associate(ex.just(.{42}), scope.getToken());
    defer owner.deinit();
    scope.close();
    var rejected = owner.clone();
    defer rejected.deinit();
    try t.expect(!rejected.isEngaged());
    try t.expectEqual(null, try rejected.sender().syncWait(.{}));
    try t.expectEqual(null, try owner.sender().syncWait(.{}));
    try t.expectEqual(42, (try owner.takeSender().syncWait(.{})).?[0]);
    try t.expect(!owner.isEngaged());
    try t.expectEqual(null, try owner.takeSender().syncWait(.{}));
    _ = try scope.join().syncWait(.{});
}

test "associated operation retains input resources across downstream scheduling" {
    var scope: ex.SimpleCountingScope = .{};
    defer scope.deinit();
    var owner = ex.associate(ex.just(.{}), scope.getToken());
    defer owner.deinit();
    var loop: ex.RunLoop = .{};
    var work_capture: Capture = .{};
    var work = ex.connect(owner.takeSender().continuesOn(loop.getScheduler()), &work_capture);
    work.start();
    try t.expect(!owner.isEngaged());
    var joined: Capture = .{};
    var join = ex.connect(scope.join(), &joined);
    join.start();
    try t.expect(!joined.finished);
    loop.finish();
    loop.run();
    try t.expect(work_capture.finished and joined.finished);
}

test "association releases only after root receiver destroys operation allocation" {
    var scope: ex.SimpleCountingScope = .{};
    defer scope.deinit();
    var owner = ex.associate(ex.just(.{}), scope.getToken());
    defer owner.deinit();
    const S = @TypeOf(owner.takeSender());
    const Connection = ex.Connection(S);
    const Root = struct {
        op: *Connection,
        freed: *bool,
        pub fn getEnv(_: *@This()) ex.Env {
            return .{};
        }
        pub fn setValue(_: *@This(), _: *const Empty) void {}
        pub fn setError(_: *@This(), _: anyerror) void {
            @panic("error");
        }
        pub fn setStopped(_: *@This()) void {
            @panic("stop");
        }
        pub fn setFinished(self: *@This()) void {
            t.allocator.destroy(self.op);
            self.freed.* = true;
        }
    };
    const Check = struct {
        freed: *bool,
        pub fn call(self: @This()) void {
            std.debug.assert(self.freed.*);
        }
    };
    var freed = false;
    var capture: Capture = .{};
    var join = ex.connect(scope.join().then(Check, .{&freed}), &capture);
    join.start();
    const op = try t.allocator.create(Connection);
    var root: Root = .{ .op = op, .freed = &freed };
    op.* = ex.connect(owner.takeSender(), &root);
    op.start();
    try t.expect(freed and capture.finished);
}

test "associated sender cancellation errors and repeat iteration retirement" {
    var scope: ex.CountingScope = .{};
    defer scope.deinit();
    var failed = ex.associate(ex.justError(Empty, error.Failed), scope.getToken());
    defer failed.deinit();
    try t.expectError(error.Failed, failed.takeSender().syncWait(.{}));
    var stop: ex.StopSource = .{};
    defer stop.deinit();
    _ = scope.requestStop();
    var stopped = ex.associate(ex.schedule(inline_scheduler), scope.getToken());
    defer stopped.deinit();
    try t.expectEqual(null, try stopped.takeSender().syncWait(.{}));
    var rounds: usize = 0;
    const Until = struct {
        rounds: *usize,
        pub fn call(self: @This()) bool {
            self.rounds.* += 1;
            return self.rounds.* == 100;
        }
    };
    var simple: ex.SimpleCountingScope = .{};
    defer simple.deinit();
    var reusable = ex.associate(ex.just(.{}).then(Until, .{&rounds}), simple.getToken());
    defer reusable.deinit();
    _ = try reusable.sender().repeatEffectUntil().syncWait(.{});
    reusable.deinit();
    _ = try simple.join().syncWait(.{});
    _ = try scope.join().syncWait(.{});
    try t.expectEqual(100, rounds);
}

test "multiple associated branches retire safely when root storage is freed" {
    var a: ex.SimpleCountingScope = .{};
    defer a.deinit();
    var b: ex.SimpleCountingScope = .{};
    defer b.deinit();
    var first = ex.associate(ex.just(.{10}), a.getToken());
    defer first.deinit();
    var second = ex.associate(ex.just(.{20}), b.getToken());
    defer second.deinit();
    const task = ex.whenAll(.{ first.takeSender(), second.takeSender() });
    const Op = ex.Connection(@TypeOf(task));
    const Root = struct {
        op: *Op,
        pub fn getEnv(_: *@This()) ex.Env {
            return .{};
        }
        pub fn setValue(_: *@This(), values: *const @TypeOf(task).Values) void {
            std.debug.assert(values[0] == 10 and values[1] == 20);
        }
        pub fn setError(_: *@This(), _: anyerror) void {
            @panic("error");
        }
        pub fn setStopped(_: *@This()) void {
            @panic("stop");
        }
        pub fn setFinished(self: *@This()) void {
            t.allocator.destroy(self.op);
        }
    };
    const op = try t.allocator.create(Op);
    var root: Root = .{ .op = op };
    op.* = ex.connect(task, &root);
    op.start();
    _ = try a.join().syncWait(.{});
    _ = try b.join().syncWait(.{});
}

test "unused association views do not acquire and take empties the owner" {
    var scope: ex.SimpleCountingScope = .{};
    defer scope.deinit();
    var original: ex.Associated(ex.Just(.{}), ex.SimpleCountingScope.Token) = ex.just(.{}).associate(scope.getToken());
    var moved = original.take();
    defer moved.deinit();
    try t.expect(!original.isEngaged());
    _ = moved.sender();
    _ = moved.takeSender();
    var capture: Capture = .{};
    _ = ex.connect(moved.sender(), &capture); // Never started, no operation lease.
    moved.deinit();
    _ = try scope.join().syncWait(.{});
}

test "whenAny keeps winning association across asynchronous downstream borrowing" {
    var scope: ex.SimpleCountingScope = .{};
    defer scope.deinit();
    var owner = ex.associate(ex.just(.{}), scope.getToken());
    defer owner.deinit();
    var loop: ex.RunLoop = .{};
    const Discard = struct {
        pub fn call(_: @This(), _: anytype) void {}
    };
    const task = ex.whenAny(.{ .winner = owner.takeSender() })
        .continuesOn(loop.getScheduler()).then(Discard, .{});
    var capture: Capture = .{};
    var op = ex.connect(task, &capture);
    op.start();
    var joined: Capture = .{};
    var join = ex.connect(scope.join(), &joined);
    join.start();
    const early = joined.finished;
    loop.finish();
    loop.run();
    try t.expect(!early);
    try t.expect(capture.finished and joined.finished);
}
