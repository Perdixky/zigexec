const s = @import("../sender.zig");
pub fn readSome(context: anytype, fd: i32, buffer: []u8, offset: u64) @import("../types.zig").ReadSome(@TypeOf(context)) {
    return s.make(.read, context, .{ .read = .{ .fd = fd, .buffer = buffer, .offset = offset } });
}
