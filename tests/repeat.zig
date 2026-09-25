const std = @import("std");
const ex = @import("zigexec");
const t = std.testing;
const support = @import("support.zig");

test "repeatUntil amortizes trampoline hops across synchronous rounds" {
    const Tick = struct {
        count: *usize,
        pub fn call(self: @This()) bool {
            self.count.* += 1;
            return self.count.* == 1000;
        }
    };
    const rounds = 1000;
    var count: usize = 0;
    const task = ex.just(.{}).then(Tick, .{&count}).repeatUntil();
    const before = ex.TrampolineScheduler.submissions();
    try t.expect((try task.syncWait(.{ .allocator = t.allocator })) != null);
    const hops = ex.TrampolineScheduler.submissions() - before;
    try t.expectEqual(rounds, count);
    // Every round still runs, but a synchronous round is consumed by the
    // execute() frame that started it, so hops grow with the budget rather
    // than with the round count.
    const budget = ex.repeatInlineRounds.*;
    try t.expect(hops <= rounds / budget + 2);
    try t.expect(hops < rounds / 4);
}

test "repeatInlineRounds tunes how many synchronous rounds share one hop" {
    const rounds = 256;
    const Tick = struct {
        count: *usize,
        pub fn call(self: @This()) bool {
            self.count.* += 1;
            return self.count.* == rounds;
        }
    };
    const previous = ex.repeatInlineRounds.*;
    defer ex.repeatInlineRounds.* = previous;
    for ([_]usize{ 1, 8, 64, 256 }) |budget| {
        ex.repeatInlineRounds.* = budget;
        var count: usize = 0;
        const task = ex.just(.{}).then(Tick, .{&count}).repeatUntil();
        const before = ex.TrampolineScheduler.submissions();
        try t.expect((try task.syncWait(.{ .allocator = t.allocator })) != null);
        const hops = ex.TrampolineScheduler.submissions() - before;
        // Every round still runs; only how many share a trampoline frame moves.
        try t.expectEqual(rounds, count);
        try t.expectEqual(rounds / budget, hops);
    }
}

test "repeatUntil performs many inline iterations without recursive stack growth" {
    const Tick = struct {
        count: *usize,
        pub fn call(self: @This()) bool {
            self.count.* += 1;
            return self.count.* == 100_000;
        }
    };
    var count: usize = 0;
    const task = ex.just(.{}).then(Tick, .{&count}).repeatUntil();
    try t.expectEqual(ex.Values(.{}), @TypeOf(task).Values);
    try t.expect((try task.syncWait(.{ .allocator = std.testing.allocator })) != null);
    try t.expectEqual(100_000, count);
}

test "repeat checks cancellation between inline effects and before the first" {
    const Tick = struct {
        count: *usize,
        stop: *ex.StopSource,
        pub fn call(self: @This()) void {
            self.count.* += 1;
            if (self.count.* == 100) _ = self.stop.requestStop();
        }
    };
    var stop: ex.StopSource = .{};
    defer stop.deinit();
    var count: usize = 0;
    const task = ex.just(.{}).then(Tick, .{ &count, &stop }).repeat().withStopToken(stop.token());
    try t.expect((try task.syncWait(.{ .allocator = std.testing.allocator })) == null);
    try t.expectEqual(100, count);
    try t.expect((try task.syncWait(.{ .allocator = std.testing.allocator })) == null);
    try t.expectEqual(100, count);
}

test "repetition stops immediately on errors or stopped and is lazy" {
    const Fail = struct {
        count: *usize,
        pub fn call(self: @This()) error{Finished}!void {
            self.count.* += 1;
            if (self.count.* == 10) return error.Finished;
        }
    };
    var count: usize = 0;
    const task = ex.just(.{}).then(Fail, .{&count}).repeat();
    try t.expectEqual(0, count);
    try t.expectError(error.Finished, task.syncWait(.{ .allocator = std.testing.allocator }));
    try t.expectEqual(10, count);
    try t.expectEqual(null, try ex.justStopped(ex.Values(.{})).repeat().syncWait(.{ .allocator = std.testing.allocator }));
    try t.expectEqual(null, try ex.justStopped(ex.Values(.{bool})).repeatUntil().syncWait(.{ .allocator = std.testing.allocator }));
    try t.expectError(error.Failed, ex.justError(ex.Values(.{bool}), error.Failed).repeatUntil().syncWait(.{ .allocator = std.testing.allocator }));
}

test "asynchronous repeats hand off drain ownership across completion threads" {
    const Tick = struct {
        count: *usize,
        pub fn call(self: @This(), allocator: std.mem.Allocator) !bool {
            try t.expectEqual(t.allocator.ptr, allocator.ptr);
            self.count.* += 1;
            return self.count.* == 10_000;
        }
    };
    const pool = try ex.ThreadPool.init(t.allocator, 4);
    defer pool.deinit();
    var count: usize = 0;
    const task = ex.readAllocator().startsOn(pool.getScheduler()).then(Tick, .{&count}).repeatUntil();
    try t.expect((try task.syncWait(.{ .allocator = t.allocator })) != null);
    try t.expectEqual(10_000, count);
}

test "repeatUntil supports deferred expression composition" {
    const Tick = struct {
        count: *usize,
        pub fn call(self: @This(), limit: usize) bool {
            self.count.* += 1;
            return self.count.* == limit;
        }
    };
    var count: usize = 0;
    const task = ex.just(@as(usize, 12)).letValue(ex.upstream().then(Tick, .{&count}).repeatUntil(), .{});
    try t.expect((try task.syncWait(.{ .allocator = std.testing.allocator })) != null);
    try t.expectEqual(12, count);
    var stop: ex.StopSource = .{};
    defer stop.deinit();
    _ = stop.requestStop();
    try t.expectEqual(null, try ex.just(.{}).letValue(ex.upstream().repeat(), .{}).withStopToken(stop.token()).syncWait(.{ .allocator = std.testing.allocator }));
}

test "terminal completion can destroy the repeating connection" {
    const task = ex.just(true).repeatUntil();
    const Receiver = struct {
        const Op = ex.Connection(@TypeOf(task), *@This());
        operation: *Op,
        done: bool = false,
        pub fn getEnv(_: *@This()) ex.Env {
            return .{ .allocator = std.testing.allocator };
        }
        pub fn setValue(self: *@This(), _: *const ex.Values(.{})) void {
            defer self.completeOwnership();
        }
        fn completeOwnership(self: *@This()) void {
            t.allocator.destroy(self.operation);
            self.done = true;
        }
        pub fn setError(self: *@This(), _: anyerror) void {
            defer self.completeOwnership();
            @panic("unexpected error");
        }
        pub fn setStopped(self: *@This()) void {
            defer self.completeOwnership();
            @panic("unexpected stop");
        }
    };
    const Op = Receiver.Op;
    const operation = try t.allocator.create(Op);
    var receiver: Receiver = .{ .operation = operation };
    ex.connectInto(operation, task, &receiver);
    operation.start();
    try t.expect(receiver.done);
}

test "cancellation reaches an asynchronous effect already waiting for stop" {
    const Cancel = struct {
        source: *ex.StopSource,
        pub fn call(self: @This()) void {
            _ = self.source.requestStop();
        }
    };
    var stop: ex.StopSource = .{};
    defer stop.deinit();
    const task = ex.whenAll(.{
        ex.asSender(support.AwaitStop{}).repeat().withStopToken(stop.token()),
        ex.just(.{}).then(Cancel, .{&stop}),
    });
    try t.expect((try task.syncWait(.{ .allocator = std.testing.allocator })) == null);
}

test "asynchronous completion may destroy a repeating connection" {
    const pool = try ex.ThreadPool.init(t.allocator, 2);
    defer pool.deinit();
    const task = ex.just(true).startsOn(pool.getScheduler()).repeatUntil();
    const Receiver = struct {
        const Op = ex.Connection(@TypeOf(task), *@This());
        operation: *Op,
        done: support.Event = .{},
        pub fn getEnv(_: *@This()) ex.Env {
            return .{ .allocator = std.testing.allocator };
        }
        pub fn setValue(self: *@This(), _: *const ex.Values(.{})) void {
            defer self.completeOwnership();
        }
        fn completeOwnership(self: *@This()) void {
            t.allocator.destroy(self.operation);
            self.done.set();
        }
        pub fn setError(self: *@This(), _: anyerror) void {
            defer self.completeOwnership();
            @panic("unexpected error");
        }
        pub fn setStopped(self: *@This()) void {
            defer self.completeOwnership();
            @panic("unexpected stop");
        }
    };
    const Op = Receiver.Op;
    const operation = try t.allocator.create(Op);
    var receiver: Receiver = .{ .operation = operation };
    ex.connectInto(operation, task, &receiver);
    operation.start();
    receiver.done.wait();
}

test "nested repeats share a trampoline and reconnect safely while queued" {
    const Inner = struct {
        count: *usize,
        pub fn call(self: @This()) bool {
            self.count.* += 1;
            return self.count.* % 100 == 0;
        }
    };
    const Outer = struct {
        count: *usize,
        pub fn call(self: @This()) bool {
            self.count.* += 1;
            return self.count.* == 1000;
        }
    };
    var inner: usize = 0;
    var outer: usize = 0;
    const task = ex.just(.{}).then(Inner, .{&inner}).repeatUntil().then(Outer, .{&outer}).repeatUntil();
    // Force every nested submission to defer until its caller returns.
    try t.expect((try task.startsOn(ex.TrampolineScheduler{ .max_depth = 1 }).syncWait(.{})) != null);
    try t.expectEqual(100_000, inner);
    try t.expectEqual(1000, outer);
}

test "old repeat names remain aliases of the canonical API" {
    try t.expectEqual(ex.Repeat(ex.Just(.{})), ex.RepeatEffect(ex.Just(.{})));
    try t.expect((try ex.just(true).repeatEffectUntil().syncWait(.{})) != null);
}

const CleanupProbe = struct {
    state: *State,
    pub const Values = ex.Values(.{bool});
    const State = struct {
        connected: usize = 0,
        started: usize = 0,
        cleaned: usize = 0,
        terminal: enum { value, err, stopped } = .value,
        scope: ?*ex.Scope = null,
    };
    pub fn Operation(comptime R: type) type {
        return struct {
            state: *State,
            receiver: ex.TypedReceiver(Values, R),
            output: Values = .{false},
            pub fn start(self: *@This()) void {
                std.debug.assert(self.receiver.getEnv().scope == self.state.scope);
                self.state.started += 1;
                if (self.state.started == 32) {
                    switch (self.state.terminal) {
                        .value => self.output = .{true},
                        .err => return self.receiver.setError(error.Finished),
                        .stopped => return self.receiver.setStopped(),
                    }
                }
                self.receiver.setValue(&self.output);
            }
            pub fn cleanup(self: *@This(), continuation: anytype) void {
                self.state.cleaned += 1;
                self.output = undefined; // repeat must already have copied the condition.
                continuation.run(); // May reconstruct or free this operation.
            }
        };
    }
    pub fn connectInto(self: @This(), out: anytype, receiver: anytype) void {
        std.debug.assert(self.state.connected == self.state.cleaned);
        self.state.connected += 1;
        out.* = .{ .state = self.state, .receiver = .init(receiver) };
    }
};

test "repeat forwards the environment and cleans each child before reconnect or terminal completion" {
    const Receiver = struct {
        state: *CleanupProbe.State,
        done: bool = false,
        pub fn getEnv(self: *@This()) ex.Env {
            return .{ .scope = self.state.scope };
        }
        pub fn setValue(self: *@This(), _: *const ex.Values(.{})) void {
            std.debug.assert(self.state.terminal == .value);
            self.finish();
        }
        pub fn setError(self: *@This(), err: anyerror) void {
            std.debug.assert(self.state.terminal == .err and err == error.Finished);
            self.finish();
        }
        pub fn setStopped(self: *@This()) void {
            std.debug.assert(self.state.terminal == .stopped);
            self.finish();
        }
        fn finish(self: *@This()) void {
            std.debug.assert(self.state.cleaned == 32);
            self.done = true;
        }
    };
    var registry: ex.Scope = .{};
    for ([_]?*ex.Scope{ null, &registry }) |scope| {
        inline for (.{ .value, .err, .stopped }) |terminal| {
            var state: CleanupProbe.State = .{ .terminal = terminal, .scope = scope };
            var receiver: Receiver = .{ .state = &state };
            const sender = ex.asSender(CleanupProbe{ .state = &state }).repeatUntil()
                .startsOn(ex.TrampolineScheduler{ .max_depth = 1 });
            // Raw connection: repeat must work without installing any Scope.
            var op: ex.meta.OperationOf(@TypeOf(sender), *Receiver) = undefined;
            sender.connectInto(&op, &receiver);
            try t.expectEqual(1, state.connected);
            try t.expectEqual(0, state.started);
            op.start();
            try t.expect(receiver.done);
            try t.expectEqual(32, state.started);
            try t.expectEqual(state.connected, state.cleaned);
        }
    }
}

test "repeat cleans the connected child when trampoline cancels before its first start" {
    var stop: ex.StopSource = .{};
    defer stop.deinit();
    _ = stop.requestStop();
    var state: CleanupProbe.State = .{};
    const sender = ex.asSender(CleanupProbe{ .state = &state }).repeatUntil();
    try t.expectEqual(null, try sender.syncWait(.{ .stop_token = stop.token() }));
    try t.expectEqual(1, state.connected);
    try t.expectEqual(1, state.cleaned);
    try t.expectEqual(0, state.started);
}
