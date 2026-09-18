const s = @import("../sender.zig");
pub fn send(context: anytype, fd: i32, buffer: []const u8, flags: u32) @import("../types.zig").Send(@TypeOf(context)) {
    return s.make(.send, context, .{ .send = .{ .fd = fd, .buffer = buffer, .flags = flags } });
}
