const std = @import("std");
const ex = @import("zigexec");
const t = std.testing;
const support = @import("support.zig");
const Empty = support.Empty;
const inline_scheduler: ex.InlineScheduler = .{};
const alloc_env: ex.Env = .{ .allocator = t.allocator };

const Capture = struct {
    completions: usize = 0,
    finished: bool = false,
    stopped: bool = false,
    err: ?anyerror = null,
    token: ex.StopToken = .{},
    done: support.Event = .{},
    scheduler: ex.StartScheduler = ex.StartScheduler.init(&inline_scheduler),
    pub fn getEnv(self: *@This()) ex.Env {
        return .{ .stop_token = self.token, .start_scheduler = self.scheduler };
    }
    pub fn setValue(self: *@This(), _: *const Empty) void {
        defer self.completeOwnership();
        self.completions += 1;
    }
    pub fn setError(self: *@This(), err: anyerror) void {
        defer self.completeOwnership();
        self.err = err;
        self.completions += 1;
    }
    pub fn setStopped(self: *@This()) void {
        defer self.completeOwnership();
        self.stopped = true;
        self.completions += 1;
    }
    fn completeOwnership(self: *@This()) void {
        self.finished = true;
        self.done.set();
    }
};
const Gate = struct {
    receiver: ex.Receiver(Empty) = undefined,
    output: Empty = .{},
    const Sender = struct {
        gate: *Gate,
        pub const Values = Empty;
        pub const can_error = false;
        pub fn Operation(comptime R: type) type {
            return struct {
                gate: *Gate,
                receiver: ex.TypedReceiver(Empty, R),
                pub fn start(self: *@This()) void {
                    self.gate.receiver = ex.Receiver(Empty).init(&self.receiver);
                }
            };
        }
        pub fn connectInto(self: @This(), out: anytype, receiver: anytype) void {
            out.* = .{ .gate = self.gate, .receiver = .init(receiver) };
        }
    };
    fn sender(self: *Gate) Sender {
        return .{ .gate = self };
    }
    fn finish(self: *Gate) void {
        self.receiver.setValue(&self.output);
    }
};
const NeverError = struct {
    pub fn call(_: @This(), err: anyerror) void {
        std.debug.panic("unexpected error: {s}", .{@errorName(err)});
    }
};
fn awaitStop() @TypeOf(ex.asSender(support.AwaitStop{}).uponError(NeverError, .{})) {
    return ex.asSender(support.AwaitStop{}).uponError(NeverError, .{});
}

test "counting scopes unused destruction empty join and repeated joins allocate nothing" {
    inline for (.{ ex.SimpleCountingScope, ex.CountingScope }) |Scope| {
        var unused: Scope = .{};
        unused.deinit();
        var closed: Scope = .{};
        closed.close();
        closed.deinit();
        var scope: Scope = .{};
        defer scope.deinit();
        try t.expect((try scope.join().syncWait(.{})) != null);
        try t.expect((try scope.join().syncWait(.{})) != null);
        try t.expect(!scope.getToken().tryAssociate().isEngaged());
    }
}

test "association ownership transfer and independent association after join starts" {
    var scope: ex.SimpleCountingScope = .{};
    defer scope.deinit();
    var first = scope.getToken().tryAssociate();
    var moved = first.take();
    try t.expect(!first.isEngaged());
    first.deinit(); // Empty is harmless.
    var capture: Capture = .{};
    var join: ex.Connection(@TypeOf(scope.join()), @TypeOf(&capture)) = undefined;
    ex.connectInto(&join, scope.join(), &capture);
    join.start();
    var second = moved.tryAssociate();
    try t.expect(second.isEngaged());
    moved.deinit();
    try t.expect(!capture.finished);
    second.deinit();
    try t.expect(capture.finished);
    try t.expect(!second.tryAssociate().isEngaged());
}

test "join permits further spawn until last association retires" {
    inline for (.{ ex.SimpleCountingScope, ex.CountingScope }) |Scope| {
        var scope: Scope = .{};
        defer scope.deinit();
        var first: Gate = .{};
        var second: Gate = .{};
        try ex.spawn(first.sender(), scope.getToken(), alloc_env);
        var capture: Capture = .{};
        var join: ex.Connection(@TypeOf(scope.join()), @TypeOf(&capture)) = undefined;
        ex.connectInto(&join, scope.join(), &capture);
        join.start();
        try ex.spawn(second.sender(), scope.getToken(), alloc_env);
        first.finish();
        try t.expect(!capture.finished);
        second.finish();
        try t.expect(capture.finished);
        try t.expectEqual(1, capture.completions);
        try t.expectError(error.ScopeClosed, ex.spawn(ex.just(.{}), scope.getToken(), alloc_env));
    }
}

test "close rejects new work without canceling existing work" {
    var scope: ex.CountingScope = .{};
    defer scope.deinit();
    var gate: Gate = .{};
    try ex.spawn(gate.sender(), scope.getToken(), alloc_env);
    scope.close();
    try t.expect(!gate.receiver.getEnv().stop_token.stopRequested());
    try t.expectError(error.ScopeClosed, ex.spawn(ex.just(.{}), scope.getToken(), alloc_env));
    var capture: Capture = .{};
    var join: ex.Connection(@TypeOf(scope.join()), @TypeOf(&capture)) = undefined;
    ex.connectInto(&join, scope.join(), &capture);
    join.start();
    gate.finish();
    try t.expect(capture.finished and !capture.stopped);
}

test "requestStop does not close and future associated work receives stop" {
    var scope: ex.CountingScope = .{};
    defer scope.deinit();
    try ex.spawn(awaitStop(), scope.getToken(), alloc_env);
    _ = scope.requestStop();
    var association = scope.getToken().tryAssociate();
    try t.expect(association.isEngaged());
    try ex.spawn(awaitStop(), scope.getToken(), alloc_env); // Stops inline.
    association.deinit();
    try t.expect((try scope.join().syncWait(.{})) != null); // Join reports no child stop.
}

test "stopped child does not cancel peers or close scope" {
    var scope: ex.CountingScope = .{};
    defer scope.deinit();
    var gate: Gate = .{};
    try ex.spawn(gate.sender(), scope.getToken(), alloc_env);
    try ex.spawn(ex.justStopped(Empty), scope.getToken(), alloc_env);
    try t.expect(!gate.receiver.getEnv().stop_token.stopRequested());
    try ex.spawn(ex.just(.{}), scope.getToken(), alloc_env);
    gate.finish();
    try t.expect((try scope.join().syncWait(.{})) != null);
}

test "join cancellation never cancels scope children or skips waiting" {
    var scope: ex.CountingScope = .{};
    defer scope.deinit();
    var stop: ex.StopSource = .{};
    defer stop.deinit();
    var gate: Gate = .{};
    try ex.spawn(gate.sender(), scope.getToken(), alloc_env);
    var capture: Capture = .{ .token = stop.token() };
    var join: ex.Connection(@TypeOf(scope.join()), @TypeOf(&capture)) = undefined;
    ex.connectInto(&join, scope.join(), &capture);
    join.start();
    _ = stop.requestStop();
    try t.expect(!capture.finished);
    try t.expect(!gate.receiver.getEnv().stop_token.stopRequested());
    gate.finish();
    // InlineScheduler observes the join receiver's cancellation on scheduling.
    try t.expect(capture.finished and capture.stopped);
}

test "multiple joiners schedule on their own environments" {
    var scope: ex.SimpleCountingScope = .{};
    defer scope.deinit();
    var association = scope.getToken().tryAssociate();
    var left_loop: ex.RunLoop = .{};
    var right_loop: ex.RunLoop = .{};
    const left_scheduler = left_loop.getScheduler();
    const right_scheduler = right_loop.getScheduler();
    var left: Capture = .{ .scheduler = ex.StartScheduler.init(&left_scheduler) };
    var right: Capture = .{ .scheduler = ex.StartScheduler.init(&right_scheduler) };
    var one: ex.Connection(@TypeOf(scope.join()), @TypeOf(&left)) = undefined;
    ex.connectInto(&one, scope.join(), &left);
    var two: ex.Connection(@TypeOf(scope.join()), @TypeOf(&right)) = undefined;
    ex.connectInto(&two, scope.join(), &right);
    one.start();
    two.start();
    association.deinit();
    try t.expect(!left.finished and !right.finished);
    left_loop.finish();
    left_loop.run();
    try t.expect(left.finished and !right.finished);
    right_loop.finish();
    right_loop.run();
    try t.expect(right.finished);
}

test "empty join completes inline even when its scheduler rejects submissions" {
    var scope: ex.SimpleCountingScope = .{};
    defer scope.deinit();
    var loop: ex.RunLoop = .{};
    loop.finish();
    const scheduler = loop.getScheduler();
    try t.expect((try scope.join().syncWait(.{ .start_scheduler = ex.StartScheduler.init(&scheduler) })) != null);
}

test "async join reports scheduler failure only after retirement" {
    var scope: ex.SimpleCountingScope = .{};
    defer scope.deinit();
    var association = scope.getToken().tryAssociate();
    var loop: ex.RunLoop = .{};
    loop.finish();
    const scheduler = loop.getScheduler();
    var capture: Capture = .{ .scheduler = ex.StartScheduler.init(&scheduler) };
    var join: ex.Connection(@TypeOf(scope.join()), @TypeOf(&capture)) = undefined;
    ex.connectInto(&join, scope.join(), &capture);
    join.start();
    try t.expect(!capture.finished);
    association.deinit();
    try t.expect(capture.finished);
    try t.expectEqual(error.SchedulerStopped, capture.err.?);
}

test "spawn allocation failures do not start work and release associations" {
    const Never = struct {
        pub fn call(_: @This()) void {
            @panic("failed spawn started work");
        }
    };
    var scope: ex.SimpleCountingScope = .{};
    defer scope.deinit();
    const sender = ex.just(.{}).then(Never, .{});
    try t.expectError(error.MissingAllocator, ex.spawn(sender, scope.getToken(), .{}));
    try t.expectError(error.OutOfMemory, ex.spawn(sender, scope.getToken(), .{ .allocator = t.failing_allocator }));
    _ = try scope.join().syncWait(.{});
}

test "spawn forwards explicit Env and reclaims synchronous completions" {
    const Check = struct {
        count: *usize,
        pub fn call(self: @This(), allocator: std.mem.Allocator) void {
            std.debug.assert(allocator.ptr == t.allocator.ptr);
            self.count.* += 1;
        }
    };
    var scope: ex.SimpleCountingScope = .{};
    defer scope.deinit();
    var count: usize = 0;
    for (0..1000) |_| try ex.spawn(ex.readAllocator().then(Check, .{&count}).uponError(NeverError, .{}), scope.getToken(), alloc_env);
    _ = try scope.join().syncWait(.{});
    try t.expectEqual(1000, count);
}

test "handled child error stays local and join has no error aggregation" {
    const Handle = struct {
        handled: *bool,
        pub fn call(self: @This(), err: anyerror) void {
            std.debug.assert(err == error.ChildFailed);
            self.handled.* = true;
        }
    };
    var scope: ex.CountingScope = .{};
    defer scope.deinit();
    var gate: Gate = .{};
    var handled = false;
    try ex.spawn(gate.sender(), scope.getToken(), alloc_env);
    try ex.spawn(ex.justError(Empty, error.ChildFailed).uponError(Handle, .{&handled}), scope.getToken(), alloc_env);
    try t.expect(handled and !gate.receiver.getEnv().stop_token.stopRequested());
    gate.finish();
    _ = try scope.join().syncWait(.{});
}

test "token wrap combines receiver and scope cancellation without acquiring association" {
    var scope: ex.CountingScope = .{};
    defer scope.deinit(); // Only wrap: scope remains unused.
    var stop: ex.StopSource = .{};
    defer stop.deinit();
    var capture: Capture = .{ .token = stop.token() };
    var op: ex.Connection(@TypeOf(scope.getToken().wrap(support.AwaitStop{})), @TypeOf(&capture)) = undefined;
    ex.connectInto(&op, scope.getToken().wrap(support.AwaitStop{}), &capture);
    op.start();
    _ = stop.requestStop();
    try t.expect(capture.finished and capture.stopped);
}

test "scope may be destroyed by first joiner while remaining joiners are notified" {
    const Destroy = struct {
        scope: *ex.SimpleCountingScope,
        done: bool = false,
        pub fn getEnv(_: *@This()) ex.Env {
            return .{ .start_scheduler = ex.StartScheduler.init(&inline_scheduler) };
        }
        pub fn setValue(self: *@This(), _: *const Empty) void {
            defer self.completeOwnership();
        }
        pub fn setError(self: *@This(), _: anyerror) void {
            defer self.completeOwnership();
            @panic("error");
        }
        pub fn setStopped(self: *@This()) void {
            defer self.completeOwnership();
            @panic("stopped");
        }
        fn completeOwnership(self: *@This()) void {
            self.scope.deinit();
            t.allocator.destroy(self.scope);
            self.done = true;
        }
    };
    const scope = try t.allocator.create(ex.SimpleCountingScope);
    scope.* = .{};
    var association = scope.getToken().tryAssociate();
    var last: Capture = .{};
    var first: Destroy = .{ .scope = scope };
    var one: ex.Connection(@TypeOf(scope.join()), @TypeOf(&last)) = undefined;
    ex.connectInto(&one, scope.join(), &last);
    var two: ex.Connection(@TypeOf(scope.join()), @TypeOf(&first)) = undefined;
    ex.connectInto(&two, scope.join(), &first);
    one.start();
    two.start();
    association.deinit();
    try t.expect(first.done and last.finished);
}

test "counting scope survives synchronous cancellation dispatch until join retirement" {
    const Destroy = struct {
        scope: *ex.CountingScope,
        done: bool = false,
        pub fn getEnv(_: *@This()) ex.Env {
            return .{ .start_scheduler = ex.StartScheduler.init(&inline_scheduler) };
        }
        pub fn setValue(self: *@This(), _: *const Empty) void {
            defer self.completeOwnership();
        }
        pub fn setError(self: *@This(), _: anyerror) void {
            defer self.completeOwnership();
            @panic("error");
        }
        pub fn setStopped(self: *@This()) void {
            defer self.completeOwnership();
            @panic("join must succeed");
        }
        fn completeOwnership(self: *@This()) void {
            self.scope.deinit();
            t.allocator.destroy(self.scope);
            self.done = true;
        }
    };
    const scope = try t.allocator.create(ex.CountingScope);
    scope.* = .{};
    for (0..32) |_| try ex.spawn(awaitStop(), scope.getToken(), alloc_env);
    var capture: Destroy = .{ .scope = scope };
    var join: ex.Connection(@TypeOf(scope.join()), @TypeOf(&capture)) = undefined;
    ex.connectInto(&join, scope.join(), &capture);
    join.start();
    _ = scope.requestStop();
    try t.expect(capture.done);
}

test "runInScope producer errors cancel children drain and report original error" {
    var scope: ex.CountingScope = .{};
    defer scope.deinit();
    try ex.spawn(awaitStop(), scope.getToken(), alloc_env);
    try t.expectError(error.AcceptFailed, ex.runInScope(&scope, ex.justError(Empty, error.AcceptFailed)).syncWait(.{}));
}

test "runInScope outer cancellation cancels producer and children then drains" {
    var scope: ex.CountingScope = .{};
    defer scope.deinit();
    var stop: ex.StopSource = .{};
    defer stop.deinit();
    try ex.spawn(awaitStop(), scope.getToken(), alloc_env);
    var capture: Capture = .{ .token = stop.token() };
    var run: ex.Connection(@TypeOf(ex.runInScope(&scope, support.AwaitStop{})), @TypeOf(&capture)) = undefined;
    ex.connectInto(&run, ex.runInScope(&scope, support.AwaitStop{}), &capture);
    run.start();
    _ = stop.requestStop();
    try t.expect(capture.finished and capture.stopped);
}

test "runInScope successful producer drains without canceling children" {
    var scope: ex.CountingScope = .{};
    defer scope.deinit();
    var gate: Gate = .{};
    try ex.spawn(gate.sender(), scope.getToken(), alloc_env);
    var capture: Capture = .{};
    var run: ex.Connection(@TypeOf(ex.runInScope(&scope, ex.just(.{}))), @TypeOf(&capture)) = undefined;
    ex.connectInto(&run, ex.runInScope(&scope, ex.just(.{})), &capture);
    run.start();
    try t.expect(!capture.finished);
    try t.expect(!gate.receiver.getEnv().stop_token.stopRequested());
    gate.finish();
    try t.expect(capture.finished and !capture.stopped);
}

test "concurrent spawn and completions while join is active" {
    const Child = struct {
        count: *std.atomic.Value(usize),
        pub fn call(self: @This()) void {
            _ = self.count.fetchAdd(1, .monotonic);
        }
    };
    const Producer = struct {
        fn run(token: ex.SimpleCountingScope.Token, scheduler: ex.ThreadPool.Scheduler, count: *std.atomic.Value(usize)) void {
            for (0..100) |_| ex.spawn(ex.schedule(scheduler).then(Child, .{count}).uponError(NeverError, .{}), token, alloc_env) catch @panic("spawn failed");
        }
    };
    const pool = try ex.ThreadPool.init(t.allocator, 4);
    defer pool.deinit();
    var scope: ex.SimpleCountingScope = .{};
    defer scope.deinit();
    var producers_alive = scope.getToken().tryAssociate();
    var count: std.atomic.Value(usize) = .init(0);
    var capture: Capture = .{};
    var join: ex.Connection(@TypeOf(scope.join()), @TypeOf(&capture)) = undefined;
    ex.connectInto(&join, scope.join(), &capture);
    join.start();
    var producers: [4]std.Thread = undefined;
    for (&producers) |*thread| thread.* = try std.Thread.spawn(.{}, Producer.run, .{ scope.getToken(), pool.getScheduler(), &count });
    for (producers) |thread| thread.join();
    producers_alive.deinit();
    _ = try scope.join().syncWait(.{});
    capture.done.wait();
    try t.expect(capture.finished);
    try t.expectEqual(400, count.load(.acquire));
}

test "spawn infers no-error property through expressions factories and recovery" {
    const Factory = struct {
        pub fn call(_: @This()) ex.Just(.{}) {
            return ex.just(.{});
        }
    };
    const Recover = struct {
        pub fn call(_: @This(), _: anyerror) ex.Just(.{}) {
            return ex.just(.{});
        }
    };
    const EmptyErrors = struct {
        pub fn call(_: @This()) error{}!void {}
    };
    var scope: ex.SimpleCountingScope = .{};
    defer scope.deinit();
    const chain = ex.just(.{}).letValue(ex.upstream().letValue(Factory, .{}).then(EmptyErrors, .{}), .{});
    try t.expect(!@TypeOf(chain).can_error);
    try ex.spawn(chain, scope.getToken(), alloc_env);
    try ex.spawn(ex.justError(Empty, error.Handled).letError(Recover, .{}), scope.getToken(), alloc_env);
    try ex.spawn(ex.whenAll(.{ ex.just(.{}), ex.just(.{}).startsOn(inline_scheduler) }), scope.getToken(), alloc_env);
    _ = try scope.join().syncWait(.{});
}

test "invalid join environment still waits for child retirement before reporting" {
    const Receiver = struct {
        err: ?anyerror = null,
        pub fn getEnv(_: *@This()) ex.Env {
            return .{};
        }
        pub fn setValue(_: *@This(), _: *const Empty) void {
            @panic("missing scheduler");
        }
        pub fn setStopped(_: *@This()) void {
            @panic("stopped");
        }
        pub fn setError(self: *@This(), err: anyerror) void {
            self.err = err;
        }
    };
    var scope: ex.SimpleCountingScope = .{};
    defer scope.deinit();
    var gate: Gate = .{};
    try ex.spawn(gate.sender(), scope.getToken(), alloc_env);
    var receiver: Receiver = .{};
    var join: ex.Connection(@TypeOf(scope.join()), @TypeOf(&receiver)) = undefined;
    ex.connectInto(&join, scope.join(), &receiver);
    join.start();
    try t.expectEqual(null, receiver.err);
    gate.finish();
    try t.expectEqual(error.MissingStartScheduler, receiver.err.?);
}

test "syncWait asynchronous join resumes on waiting thread by default" {
    const Work = struct {
        entered: *support.Event,
        pub fn call(self: @This()) void {
            self.entered.wait();
        }
    };
    const BeginJoin = struct {
        const Self = @This();
        entered: *support.Event,
        scope: *ex.SimpleCountingScope,
        pub const Values = Empty;
        pub fn Operation(comptime R: type) type {
            return struct {
                sender: Self,
                receiver: ex.TypedReceiver(Empty, R),
                join_op: ex.SimpleCountingScope.Join.Operation(ex.TypedReceiver(Empty, R)) = undefined,
                pub fn start(self: *@This()) void {
                    self.sender.scope.join().connectInto(&self.join_op, self.receiver);
                    self.join_op.start(); // Registered while worker is still blocked.
                    self.sender.entered.set();
                }
            };
        }
        pub fn connectInto(self: @This(), out: anytype, receiver: anytype) void {
            out.* = .{ .sender = self, .receiver = .init(receiver) };
        }
    };
    const CheckThread = struct {
        expected: std.Thread.Id,
        pub fn call(self: @This()) !void {
            try t.expectEqual(self.expected, std.Thread.getCurrentId());
        }
    };
    const pool = try ex.ThreadPool.init(t.allocator, 1);
    defer pool.deinit();
    var entered: support.Event = .{};
    var scope: ex.SimpleCountingScope = .{};
    defer scope.deinit();
    try ex.spawn(ex.schedule(pool.getScheduler()).then(Work, .{&entered}).uponError(NeverError, .{}), scope.getToken(), alloc_env);
    _ = try ex.asSender(BeginJoin{ .entered = &entered, .scope = &scope }).then(CheckThread, .{std.Thread.getCurrentId()}).syncWait(.{});
}

test "runInScope pre-cancellation and cancellation after producer retirement" {
    var stop: ex.StopSource = .{};
    defer stop.deinit();
    var scope: ex.CountingScope = .{};
    defer scope.deinit();
    try ex.spawn(awaitStop(), scope.getToken(), alloc_env);
    var capture: Capture = .{ .token = stop.token() };
    var run: ex.Connection(@TypeOf(ex.runInScope(&scope, ex.just(.{}))), @TypeOf(&capture)) = undefined;
    ex.connectInto(&run, ex.runInScope(&scope, ex.just(.{})), &capture);
    run.start();
    try t.expect(!capture.finished);
    _ = stop.requestStop();
    try t.expect(capture.finished and capture.stopped);
    var other: ex.CountingScope = .{};
    defer other.deinit();
    try t.expectEqual(null, try ex.runInScope(&other, support.AwaitStop{}).syncWait(.{ .stop_token = stop.token() }));
}

test "spawn deallocates operation before releasing the scope association" {
    const Check = struct {
        allocator: *t.FailingAllocator,
        pub fn call(self: @This()) void {
            std.debug.assert(self.allocator.allocations == 1);
            std.debug.assert(self.allocator.deallocations == 1);
            std.debug.assert(self.allocator.allocated_bytes == self.allocator.freed_bytes);
        }
    };
    var allocator = t.FailingAllocator.init(t.allocator, .{});
    var scope: ex.SimpleCountingScope = .{};
    defer scope.deinit();
    var gate: Gate = .{};
    try ex.spawn(gate.sender(), scope.getToken(), .{ .allocator = allocator.allocator() });
    var capture: Capture = .{};
    var join: ex.Connection(@TypeOf(scope.join().then(Check, .{&allocator})), @TypeOf(&capture)) = undefined;
    ex.connectInto(&join, scope.join().then(Check, .{&allocator}), &capture);
    join.start();
    try t.expectEqual(0, allocator.deallocations);
    gate.finish();
    try t.expect(capture.finished);
}
