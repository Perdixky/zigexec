const s = @import("../sender.zig");
pub fn recv(context: anytype, fd: i32, buffer: []u8, flags: u32) @import("../types.zig").Recv(@TypeOf(context)) {
    return s.make(.recv, context, .{ .recv = .{ .fd = fd, .buffer = buffer, .flags = flags } });
}
