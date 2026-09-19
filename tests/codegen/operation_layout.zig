//! Compare the payload storage of a producer and a chain of forwarding nodes.
const std = @import("std");
const ex = @import("zigexec");
pub fn main() void {
    const source = ex.just(@as([65536]u8, undefined));
    const task = source.letValue(
        ex.upstream().letValue(ex.upstream(), .{}).continuesOn(ex.InlineScheduler{}),
        .{},
    ).withStopToken(.{});
    std.debug.print("source operation: {d} bytes; composed operation: {d} bytes\n", .{
        @sizeOf(@TypeOf(source).Operation), @sizeOf(@TypeOf(task).Operation),
    });
}
