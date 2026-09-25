const std = @import("std");
const ex = @import("zigexec");
const t = std.testing;
const Empty = ex.Values(.{});

const Capture = struct {
    completed: bool = false,
    finished: bool = false,
    pub fn getEnv(_: *@This()) ex.Env {
        return .{};
    }
    pub fn setValue(self: *@This(), _: *const Empty) void {
        defer self.completeOwnership();
        self.completed = true;
    }
    pub fn setError(self: *@This(), _: anyerror) void {
        defer self.completeOwnership();
        @panic("unexpected error");
    }
    pub fn setStopped(self: *@This()) void {
        defer self.completeOwnership();
        @panic("unexpected stop");
    }
    fn completeOwnership(self: *@This()) void {
        self.finished = true;
    }
};

// Captures its final address at connection time, before any start call.
const Probe = struct {
    connects: *usize,
    starts: *usize,
    pub const Values = Empty;
    pub const can_error = false;
    pub fn Operation(comptime R: type) type {
        return struct {
            receiver: ex.TypedReceiver(Empty, R),
            starts: *usize,
            address: *@This() = undefined,
            pub fn start(self: *@This()) void {
                std.debug.assert(self.address == self);
                self.starts.* += 1;
                self.receiver.setValue(&.{});
            }
        };
    }
    pub fn connectInto(self: @This(), out: anytype, receiver: anytype) void {
        self.connects.* += 1;
        out.* = .{ .receiver = .init(receiver), .starts = self.starts };
        out.address = out;
    }
};

test "known children connect in final storage before start, including scheduling and joins" {
    var connects: usize = 0;
    var starts: usize = 0;
    const probe = ex.asSender(Probe{ .connects = &connects, .starts = &starts });
    const Ignore = struct {
        pub fn call(_: @This(), _: anytype) void {}
    };
    const task = ex.whenAll(.{
        probe.startsOn(ex.InlineScheduler{}).continuesOn(ex.InlineScheduler{}).withStopToken(.{}),
        ex.just(.{}).letValue(probe, .{}),
        ex.whenAny(.{ probe, probe }).then(Ignore, .{}),
    });
    var capture: Capture = .{};
    var op: ex.Connection(@TypeOf(task), *Capture) = undefined;
    ex.connectInto(&op, task, &capture);
    try t.expectEqual(4, connects);
    try t.expectEqual(0, starts);
    try t.expect(!capture.completed and !capture.finished);
    op.start();
    try t.expectEqual(4, connects);
    try t.expectEqual(4, starts);
    try t.expect(capture.completed and capture.finished);
}

test "factory continuation connects only when upstream supplies its values" {
    const Factory = struct {
        connects: *usize,
        starts: *usize,
        calls: *usize,
        pub fn call(self: *@This(), value: usize) Probe {
            std.debug.assert(value == 42);
            self.calls.* += 1;
            return .{ .connects = self.connects, .starts = self.starts };
        }
    };
    var connects: usize = 0;
    var starts: usize = 0;
    var calls: usize = 0;
    const task = ex.just(@as(usize, 42)).letValue(Factory, .{ &connects, &starts, &calls });
    var capture: Capture = .{};
    var op: ex.Connection(@TypeOf(task), *Capture) = undefined;
    ex.connectInto(&op, task, &capture);
    try t.expectEqual(0, connects + starts + calls);
    op.start();
    try t.expectEqual(1, connects);
    try t.expectEqual(1, starts);
    try t.expectEqual(1, calls);
    try t.expect(capture.finished);
}

test "large factory capture occurs once across ordinary adaptors and root" {
    const Factory = struct {
        buffer: [16 * 1024]u8 = @splat(37),
        pub fn call(self: *@This()) ex.Just(.{[]const u8}) {
            return ex.just(.{@as([]const u8, &self.buffer)});
        }
    };
    const Check = struct {
        address: *usize,
        pub fn call(self: @This(), bytes: []const u8) void {
            std.debug.assert(bytes.len == 16 * 1024 and bytes[0] == 37 and bytes[bytes.len - 1] == 37);
            self.address.* = @intFromPtr(bytes.ptr);
        }
    };
    const Noop = struct {
        pub fn call(_: @This()) void {}
    };
    const Recover = struct {
        pub fn call(_: @This(), _: anyerror) void {}
    };
    var address: usize = 0;
    const source = ex.just(.{}).letValue(Factory, .{});
    const task = source.then(Check, .{&address}).then(Noop, .{}).uponError(Recover, .{}).withStopToken(.{}).startsOn(ex.InlineScheduler{});
    const Op = ex.Connection(@TypeOf(task), *Capture);
    try t.expect(@sizeOf(Op) < @sizeOf(Factory) + 2048);
    try t.expectEqual(@sizeOf(*Capture), @sizeOf(ex.TypedReceiver(Empty, *Capture)));
    var capture: Capture = .{};
    var op: Op = undefined;
    ex.connectInto(&op, task, &capture);
    op.start();
    try t.expect(capture.finished);
    try t.expect(address >= @intFromPtr(&op));
    try t.expect(address + 16 * 1024 <= @intFromPtr(&op) + @sizeOf(Op));
}

test "custom senders compose with built-ins when they implement the typed protocol" {
    const Custom = struct {
        pub const Values = Empty;
        pub const can_error = false;
        pub fn Operation(comptime R: type) type {
            return struct {
                receiver: ex.TypedReceiver(Empty, R),
                pub fn start(self: *@This()) void {
                    self.receiver.setValue(&.{});
                }
            };
        }
        pub fn connectInto(_: @This(), out: anytype, receiver: anytype) void {
            out.* = .{ .receiver = .init(receiver) };
        }
    };
    const task = ex.whenAll(.{ ex.asSender(Custom{}).startsOn(ex.InlineScheduler{}), Custom{} });
    var capture: Capture = .{};
    var op: ex.Connection(@TypeOf(task), *Capture) = undefined;
    ex.connectInto(&op, task, &capture);
    op.start();
    try t.expect(capture.completed and capture.finished);
}
