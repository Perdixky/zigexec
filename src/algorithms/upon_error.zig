const c = @import("../execution/protocol.zig");
const Transform = @import("detail/transform.zig").Transform;
pub fn uponError(sender: anytype, callback: anytype) Transform(@TypeOf(sender), c.Stored(@TypeOf(callback)), .err) {
    return .{ .sender = sender, .callback = callback };
}
