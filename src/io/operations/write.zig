const s = @import("../sender.zig");
pub fn writeSome(context: anytype, fd: i32, buffer: []const u8, offset: u64) @import("../types.zig").WriteSome(@TypeOf(context)) {
    return s.make(.write, context, .{ .write = .{ .fd = fd, .buffer = buffer, .offset = offset } });
}
