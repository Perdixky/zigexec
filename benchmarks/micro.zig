//! CPU-bound microbenchmarks for the execution machinery itself. Unlike the TCP
//! echo comparison, these keep the kernel network stack out of the measurement
//! so per-operation framework costs are visible.
//!
//!   zig build bench -Doptimize=ReleaseFast [-- filter]
//!
//! Each line reports the median of several runs in ns per operation.
const std = @import("std");
const ex = @import("zigexec");
const linux = std.os.linux;
const Io = ex.io.For(*ex.IoUring);

fn now() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

var sink: u64 = 0;

const Inc = struct {
    pub fn call(_: @This(), value: i64) i64 {
        return value + 1;
    }
};
const Countdown = struct {
    remaining: *usize,
    pub fn call(self: @This()) bool {
        self.remaining.* -= 1;
        return self.remaining.* == 0;
    }
};

fn syncWaitJust(n: usize) !void {
    for (0..n) |i| {
        const result = (try ex.just(.{@as(i64, @intCast(i))}).then(Inc, .{}).syncWait(.{})).?;
        sink +%= @intCast(result[0]);
    }
}

fn repeatInline(n: usize) !void {
    var remaining = n;
    _ = try ex.just(.{}).then(Countdown, .{&remaining}).repeatUntil().syncWait(.{});
}

fn whenAll3(n: usize) !void {
    for (0..n) |i| {
        const v: i64 = @intCast(i);
        const result = (try ex.whenAll(.{ ex.just(.{v}), ex.just(.{v}), ex.just(.{v}) }).syncWait(.{})).?;
        sink +%= @intCast(result[0] + result[1] + result[2]);
    }
}

fn letValueChain(n: usize) !void {
    const Next = struct {
        pub fn call(_: @This(), value: i64) ex.Just(.{i64}) {
            return ex.just(.{value + 1});
        }
    };
    var remaining = n;
    const Step = struct {
        remaining: *usize,
        pub fn call(self: @This(), _: i64) bool {
            self.remaining.* -= 1;
            return self.remaining.* == 0;
        }
    };
    _ = try ex.just(.{@as(i64, 1)}).letValue(Next, .{}).then(Step, .{&remaining}).repeatUntil().syncWait(.{});
}

/// Every iteration is a real enqueue/dequeue on a RunLoop driven by this thread.
fn runLoopSchedule(n: usize) !void {
    var loop: ex.RunLoop = .{};
    var remaining = n;
    const Done = struct {
        loop: *ex.RunLoop,
        pub fn getEnv(_: *@This()) ex.UnstoppableEnv {
            return .{};
        }
        pub fn setValue(self: *@This(), _: *const ex.Values(.{})) void {
            self.loop.finish();
        }
        pub fn setError(_: *@This(), _: anyerror) void {
            @panic("run loop failed");
        }
        pub fn setStopped(_: *@This()) void {
            @panic("run loop stopped");
        }
    };
    var done: Done = .{ .loop = &loop };
    const sender = ex.schedule(loop.getScheduler()).then(Countdown, .{&remaining}).repeatUntil();
    var operation: ex.Connection(@TypeOf(sender), *Done) = undefined;
    ex.connectInto(&operation, sender, &done);
    operation.start();
    loop.run();
}

/// Round trip: hop onto a worker and back to the waiting thread.
fn poolRoundTrip(pool: *ex.ThreadPool, n: usize) !void {
    for (0..n) |i| {
        const result = (try ex.just(.{@as(i64, @intCast(i))}).startsOn(pool.getScheduler()).then(Inc, .{}).syncWait(.{})).?;
        sink +%= @intCast(result[0]);
    }
}

/// Eight independent loops of pool hops joined once, contending on the queue.
fn poolFanOut(pool: *ex.ThreadPool, n: usize) !void {
    const per = n / 8;
    var counters: [8]usize = @splat(per);
    const s = pool.getScheduler();
    const Loop = struct {
        fn make(scheduler: ex.ThreadPool.Scheduler, counter: *usize) ex.RepeatUntil(ex.Then(ex.Schedule(ex.ThreadPool.Scheduler), Countdown)) {
            return ex.schedule(scheduler).then(Countdown, .{counter}).repeatUntil();
        }
    };
    _ = try ex.whenAll(.{
        Loop.make(s, &counters[0]), Loop.make(s, &counters[1]), Loop.make(s, &counters[2]), Loop.make(s, &counters[3]),
        Loop.make(s, &counters[4]), Loop.make(s, &counters[5]), Loop.make(s, &counters[6]), Loop.make(s, &counters[7]),
    }).syncWait(.{});
}

/// One nop at a time: framework cost plus one io_uring_enter per operation.
fn uringSerial(context: *ex.IoUring, n: usize) !void {
    var remaining = n;
    _ = try context.getScheduler().schedule().then(Countdown, .{&remaining}).repeatUntil().syncWait(.{});
}

/// Many independent nop loops on the reactor, similar in shape to the echo
/// server's per-connection repeat loops but without socket work.
fn Lanes(comptime stoppable: bool) type {
    return struct {
        const lane_count = 256;
        const Base = ex.RepeatUntil(ex.Then(Io.Schedule, Countdown));
        const Loop = if (stoppable) ex.WithStopToken(Base) else Base;
        const Lane = struct {
            group: *Group,
            remaining: usize,
            operation: ex.Connection(Loop, *Lane) = undefined,
            pub fn getEnv(_: *Lane) ex.UnstoppableEnv {
                return .{};
            }
            pub fn setValue(self: *Lane, _: *const ex.Values(.{})) void {
                self.group.finished += 1;
                if (self.group.finished == lane_count) self.group.done.finish();
            }
            pub fn setError(_: *Lane, _: anyerror) void {
                @panic("lane failed");
            }
            pub fn setStopped(_: *Lane) void {
                @panic("lane stopped");
            }
        };
        const Group = struct {
            context: *ex.IoUring,
            lanes: [lane_count]Lane = undefined,
            finished: usize = 0,
            done: ex.RunLoop = .{},
            stop: ex.StopSource = .{},
            launch_task: ex.ScheduleTask = .{ .run = launch },
            fn launch(task: *ex.ScheduleTask) void {
                const self: *Group = @fieldParentPtr("launch_task", task);
                for (&self.lanes) |*lane| {
                    const base = Io.Schedule{ .inner = .{ .context = self.context, .description = .nop } };
                    const loop = base.then(Countdown, .{&lane.remaining}).repeatUntil();
                    if (stoppable)
                        ex.connectInto(&lane.operation, loop.withStopToken(self.stop.token()), lane)
                    else
                        ex.connectInto(&lane.operation, loop, lane);
                    lane.operation.start();
                }
            }
        };
        fn run(context: *ex.IoUring, n: usize) !void {
            const group = try std.heap.page_allocator.create(Group);
            defer std.heap.page_allocator.destroy(group);
            group.* = .{ .context = context };
            for (&group.lanes) |*lane| lane.* = .{ .group = group, .remaining = n / lane_count };
            try context.getScheduler().submit(&group.launch_task);
            group.done.run();
        }
    };
}

/// Hand-written io_uring loop with the same concurrency, for a lower bound.
fn rawUringLanes(n: usize) !void {
    var ring = try linux.IoUring.init(64, 0);
    defer ring.deinit();
    const lanes = 256;
    var remaining: [lanes]usize = @splat(n / lanes);
    var queued: [lanes]u32 = undefined;
    var queued_len: usize = lanes;
    for (&queued, 0..) |*q, i| q.* = @intCast(i);
    var live: usize = lanes;
    var cqes: [64]linux.io_uring_cqe = undefined;
    while (live > 0) {
        while (queued_len > 0) {
            const sqe = ring.get_sqe() catch break;
            queued_len -= 1;
            sqe.prep_nop();
            sqe.user_data = queued[queued_len];
        }
        _ = try ring.submit_and_wait(if (queued_len > 0) 0 else 1);
        const count = try ring.copy_cqes(&cqes, 0);
        for (cqes[0..count]) |cqe| {
            const lane: u32 = @intCast(cqe.user_data);
            remaining[lane] -= 1;
            if (remaining[lane] == 0) live -= 1 else {
                queued[queued_len] = lane;
                queued_len += 1;
            }
        }
    }
}

const Benchmark = struct {
    name: []const u8,
    ops: usize,
};

fn measure(name: []const u8, filter: ?[]const u8, ops: usize, runs: usize, function: anytype, args: anytype) !void {
    if (filter) |f| if (std.mem.indexOf(u8, name, f) == null) return;
    // Warm up allocator paths, page faults, and worker threads.
    try @call(.auto, function, args ++ .{@max(ops / 10, 1)});
    var samples: [16]f64 = undefined;
    for (samples[0..runs]) |*sample| {
        const begin = now();
        try @call(.auto, function, args ++ .{ops});
        sample.* = @as(f64, @floatFromInt(now() - begin)) / @as(f64, @floatFromInt(ops));
    }
    std.mem.sort(f64, samples[0..runs], {}, std.sort.asc(f64));
    std.debug.print("{s:<28} {d:>10.1} ns/op   (min {d:.1}, max {d:.1})\n", .{ name, samples[runs / 2], samples[0], samples[runs - 1] });
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();
    const filter = args.next();
    const runs = 7;

    try measure("sync_wait/just.then", filter, 1_000_000, runs, syncWaitJust, .{});
    try measure("repeat_until/inline", filter, 10_000_000, runs, repeatInline, .{});
    try measure("let_value/repeat", filter, 10_000_000, runs, letValueChain, .{});
    try measure("when_all/3xjust", filter, 1_000_000, runs, whenAll3, .{});
    try measure("run_loop/schedule", filter, 5_000_000, runs, runLoopSchedule, .{});

    const pool = try ex.ThreadPool.init(std.heap.page_allocator, 4);
    defer pool.deinit();
    try measure("thread_pool/round_trip", filter, 100_000, runs, poolRoundTrip, .{pool});
    try measure("thread_pool/fan_out_8", filter, 800_000, runs, poolFanOut, .{pool});
    const single = try ex.ThreadPool.init(std.heap.page_allocator, 1);
    defer single.deinit();
    try measure("thread_pool/fan_out_8_1worker", filter, 800_000, runs, poolFanOut, .{single});

    const context = try ex.IoUring.init(std.heap.page_allocator, .{});
    defer context.deinit();
    try measure("io_uring/nop_serial", filter, 1_000_000, runs, uringSerial, .{context});
    try measure("io_uring/nop_256_lanes", filter, 5_120_000, runs, Lanes(false).run, .{context});
    try measure("io_uring/nop_256_stoppable", filter, 5_120_000, runs, Lanes(true).run, .{context});
    try measure("raw_uring/nop_256_lanes", filter, 5_120_000, runs, rawUringLanes, .{});
    std.mem.doNotOptimizeAway(sink);
}
