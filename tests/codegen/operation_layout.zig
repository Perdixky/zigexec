//! Compare the payload storage of a producer and a chain of forwarding nodes.
const std = @import("std");
const ex = @import("zigexec");
const Probe = struct {
    pub fn getEnv(_: *@This()) ex.Env {
        return .{};
    }
    pub fn setValue(_: *@This(), _: *const ex.Values(.{[65536]u8})) void {}
    pub fn setError(_: *@This(), _: anyerror) void {}
    pub fn setStopped(_: *@This()) void {}
};
pub fn main() void {
    const source = ex.just(@as([65536]u8, undefined));
    const task = source.letValue(
        ex.upstream().letValue(ex.upstream(), .{}).continuesOn(ex.InlineScheduler{}),
        .{},
    ).withStopToken(.{});
    std.debug.print("source operation: {d} bytes; composed operation: {d} bytes\n", .{
        @sizeOf(@TypeOf(source).Operation(*Probe)), @sizeOf(@TypeOf(task).Operation(*Probe)),
    });
}
