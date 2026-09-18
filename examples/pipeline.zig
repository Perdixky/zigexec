const std = @import("std");
const ex = @import("zigexec");

const Square = struct {
    pub fn call(_: @This(), value: i64) i64 {
        return value * value;
    }
};

const Sum = struct {
    pub fn call(_: @This(), a: i64, b: i64, c: i64) i64 {
        return a + b + c;
    }
};

pub fn main() !void {
    const pool = try ex.ThreadPool.init(std.heap.page_allocator, 3);
    defer pool.deinit();
    const cpu = pool.getScheduler();

    const work = ex.whenAll(.{
        ex.just(.{3}).then(Square, .{}).startsOn(cpu),
        ex.just(.{4}).then(Square, .{}).startsOn(cpu),
        ex.just(.{5}).then(Square, .{}).startsOn(cpu),
    }).then(Sum, .{});
    const result = (try work.syncWait(.{ .allocator = std.heap.page_allocator })) orelse return;
    std.debug.print("3² + 4² + 5² = {d}\n", .{result[0]});
}
