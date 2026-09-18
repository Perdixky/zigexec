const s = @import("../sender.zig");
pub fn close(context: anytype, fd: i32) @import("../types.zig").Close(@TypeOf(context)) {
    return s.make(.close, context, .{ .close = fd });
}
