const s = @import("../sender.zig");
pub fn accept(context: anytype, fd: i32, flags: u32) @import("../types.zig").Accept(@TypeOf(context)) {
    return s.make(.accept, context, .{ .accept = .{ .fd = fd, .flags = flags } });
}
