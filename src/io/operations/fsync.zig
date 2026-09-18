const s = @import("../sender.zig");
pub fn fsync(context: anytype, fd: i32) @import("../types.zig").Fsync(@TypeOf(context)) {
    return s.make(.fsync, context, .{ .fsync = fd });
}
