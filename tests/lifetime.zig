const std = @import("std");
const ex = @import("zigexec");
const t = std.testing;
const support = @import("support.zig");
const Event = support.Event;
const Payload = [64 * 1024]u8;
const BigValues = ex.Values(.{Payload});

// No big payload in the sender: only the operation owns the produced bytes.
const LargeSource = struct {
    origin: *?*const BigValues,
    pub const Values = BigValues;
    pub const Operation = struct {
        origin: *?*const BigValues,
        output: Values = undefined,
        receiver: ex.Receiver(Values),
        pub fn start(self: *@This()) void {
            @memset(&self.output[0], 37);
            self.origin.* = &self.output;
            self.receiver.setValue(&self.output);
        }
    };
    pub fn connect(self: @This(), receiver: ex.Receiver(Values)) Operation {
        return .{ .origin = self.origin, .receiver = receiver };
    }
};

test "64 KiB value keeps its address through scopes scheduling and stop forwarding" {
    var origin: ?*const BigValues = null;
    var loop: ex.RunLoop = .{};
    var stop: ex.StopSource = .{};
    defer stop.deinit();
    const task = ex.asSender(LargeSource{ .origin = &origin })
        .letValue(ex.upstream().letValue(ex.upstream(), .{}).continuesOn(loop.getScheduler()), .{})
        .withStopToken(stop.token());
    const Capture = struct {
        values: ?*const BigValues = null,
        finished: bool = false,
        pub fn getEnv(_: *@This()) ex.Env {
            return .{ .allocator = t.allocator };
        }
        pub fn setValue(self: *@This(), values: *const BigValues) void {
            self.values = values;
        }
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
    var capture: Capture = .{};
    var connection = ex.connect(task, &capture);
    connection.start();
    try t.expect(!capture.finished);
    try t.expectEqual(null, capture.values);
    loop.finish();
    loop.run();
    try t.expect(capture.finished);
    try t.expectEqual(origin.?, capture.values.?);
    try t.expectEqual(37, capture.values.?.*[0][0]);
    try t.expectEqual(37, capture.values.?.*[0][@sizeOf(Payload) - 1]);
    // Forwarding nodes add only fixed-size metadata, not another 64 KiB tuple.
    try t.expect(@sizeOf(@TypeOf(task).Operation) < @sizeOf(LargeSource.Operation) + 8192);
}

test "then materializes large results in its operation before asynchronous consumption" {
    const Produce = struct {
        pub fn call(_: @This()) Payload {
            return @splat(23);
        }
    };
    var loop: ex.RunLoop = .{};
    const source = ex.just(.{}).then(Produce, .{});
    const task = source.letValue(ex.upstream().continuesOn(loop.getScheduler()), .{});
    const Capture = struct {
        values: ?*const BigValues = null,
        pub fn getEnv(_: *@This()) ex.Env {
            return .{ .allocator = t.allocator };
        }
        pub fn setValue(self: *@This(), values: *const BigValues) void {
            self.values = values;
        }
        pub fn setError(_: *@This(), _: anyerror) void {
            @panic("unexpected error");
        }
        pub fn setStopped(_: *@This()) void {
            @panic("unexpected stop");
        }
    };
    var capture: Capture = .{};
    var connection = ex.connect(task, &capture);
    connection.start();
    loop.finish();
    loop.run();
    const address = @intFromPtr(capture.values.?);
    try t.expect(address >= @intFromPtr(&connection));
    try t.expect(address + @sizeOf(BigValues) <= @intFromPtr(&connection) + @sizeOf(@TypeOf(connection)));
    try t.expectEqual(23, capture.values.?.*[0][@sizeOf(Payload) - 1]);
}

// A real asynchronous producer deliberately continues using its operation after
// setValue returns. Its execution entry covers that entire interval.
const PausedSource = struct {
    published: *Event,
    proceed: *Event,
    exited: *std.atomic.Value(bool),
    pub const Values = ex.Values(.{i64});
    pub const Operation = struct {
        sender: PausedSource,
        receiver: ex.Receiver(Values),
        output: Values = .{42},
        pub fn start(self: *@This()) void {
            const scope = self.receiver.env.scope;
            ex.Scope.acquire(scope);
            const thread = std.Thread.spawn(.{}, run, .{self}) catch |err| {
                self.receiver.setError(err);
                ex.Scope.release(scope);
                return;
            };
            thread.detach();
        }
        fn run(self: *@This()) void {
            const scope = self.receiver.env.scope;
            self.receiver.setValue(&self.output);
            self.sender.published.set();
            self.sender.proceed.wait();
            std.debug.assert(self.output[0] == 42);
            self.sender.exited.store(true, .release);
            ex.Scope.release(scope); // Last access; retirement may destroy self.
        }
    };
    pub fn connect(self: PausedSource, receiver: ex.Receiver(Values)) Operation {
        return .{ .sender = self, .receiver = receiver };
    }
};

test "root retirement waits until producer has finished post-completion accesses" {
    var published: Event = .{};
    var proceed: Event = .{};
    var exited: std.atomic.Value(bool) = .init(false);
    const sender: PausedSource = .{ .published = &published, .proceed = &proceed, .exited = &exited };
    const Connection = ex.Connection(PausedSource);
    const Capture = struct {
        connection: *Connection,
        exited: *std.atomic.Value(bool),
        value: i64 = 0,
        retired: std.atomic.Value(bool) = .init(false),
        done: Event = .{},
        pub fn getEnv(_: *@This()) ex.Env {
            return .{ .allocator = t.allocator };
        }
        pub fn setValue(self: *@This(), values: *const PausedSource.Values) void {
            self.value = values.*[0];
        }
        pub fn setError(_: *@This(), _: anyerror) void {
            @panic("unexpected error");
        }
        pub fn setStopped(_: *@This()) void {
            @panic("unexpected stop");
        }
        pub fn setFinished(self: *@This()) void {
            std.debug.assert(self.exited.load(.acquire));
            t.allocator.destroy(self.connection);
            self.retired.store(true, .release);
            self.done.set();
        }
    };
    const connection = try t.allocator.create(Connection);
    var capture: Capture = .{ .connection = connection, .exited = &exited };
    connection.* = ex.connect(sender, &capture);
    connection.start();
    published.wait();
    const premature = capture.retired.load(.acquire);
    proceed.set();
    capture.done.wait();
    try t.expect(!premature);
    try t.expectEqual(42, capture.value);
}

test "syncWait returns only after producer scope exits" {
    var published: Event = .{};
    var proceed: Event = .{};
    var exited: std.atomic.Value(bool) = .init(false);
    const sender: PausedSource = .{ .published = &published, .proceed = &proceed, .exited = &exited };
    const Waiter = struct {
        sender: PausedSource,
        returned: std.atomic.Value(bool) = .init(false),
        result: i64 = 0,
        fn run(self: *@This()) void {
            const values = ex.syncWait(self.sender, .{ .allocator = t.allocator }) catch @panic("wait failed");
            std.debug.assert(self.sender.exited.load(.acquire));
            self.result = values.?[0];
            self.returned.store(true, .release);
        }
    };
    var waiter: Waiter = .{ .sender = sender };
    const thread = try std.Thread.spawn(.{}, Waiter.run, .{&waiter});
    published.wait();
    const premature = waiter.returned.load(.acquire);
    proceed.set();
    thread.join();
    try t.expect(!premature);
    try t.expectEqual(42, waiter.result);
}

test "repeat does not overwrite the previous iteration during its completion handler" {
    const Effect = struct {
        round: *std.atomic.Value(usize),
        pub const Values = ex.Values(.{bool});
        pub const Operation = struct {
            round: *std.atomic.Value(usize),
            receiver: ex.Receiver(Values),
            generation: usize = 0,
            output: Values = undefined,
            pub fn start(self: *@This()) void {
                self.generation = self.round.fetchAdd(1, .monotonic) + 1;
                const scope = self.receiver.env.scope;
                ex.Scope.acquire(scope);
                const thread = std.Thread.spawn(.{}, run, .{self}) catch |err| {
                    self.receiver.setError(err);
                    ex.Scope.release(scope);
                    return;
                };
                thread.detach();
            }
            fn run(self: *@This()) void {
                const scope = self.receiver.env.scope;
                const generation = self.generation;
                self.output = .{generation == 100};
                self.receiver.setValue(&self.output);
                // Reconstruction would reset/replace these fields if the old
                // repeat algorithm restarted from within setValue.
                std.debug.assert(self.generation == generation);
                std.debug.assert(self.round.load(.monotonic) == generation);
                ex.Scope.release(scope);
            }
        };
        pub fn connect(self: @This(), receiver: ex.Receiver(Values)) Operation {
            return .{ .round = self.round, .receiver = receiver };
        }
    };
    var round: std.atomic.Value(usize) = .init(0);
    _ = try ex.asSender(Effect{ .round = &round }).repeatEffectUntil().syncWait(.{ .allocator = t.allocator });
    try t.expectEqual(100, round.load(.monotonic));
}

test "shared results remain owned by each subscription across scheduling and owner release" {
    var origin: ?*const BigValues = null;
    var shared = try ex.asSender(LargeSource{ .origin = &origin }).split(t.allocator);
    var loop: ex.RunLoop = .{};
    const task = shared.sender().continuesOn(loop.getScheduler());
    const Capture = struct {
        values: ?*const BigValues = null,
        pub fn getEnv(_: *@This()) ex.Env {
            return .{ .allocator = t.allocator };
        }
        pub fn setValue(self: *@This(), values: *const BigValues) void {
            self.values = values;
        }
        pub fn setError(_: *@This(), _: anyerror) void {
            @panic("unexpected error");
        }
        pub fn setStopped(_: *@This()) void {
            @panic("unexpected stop");
        }
    };
    var capture: Capture = .{};
    var connection = ex.connect(task, &capture);
    connection.start();
    shared.deinit();
    // The shared cache is gone before the subscriber consumes its own result.
    loop.finish();
    loop.run();
    try t.expectEqual(37, capture.values.?.*[0][@sizeOf(Payload) - 1]);
}
