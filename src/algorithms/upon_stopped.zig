const c = @import("../execution/protocol.zig");
const Transform = @import("detail/transform.zig").Transform;
pub fn uponStopped(sender: anytype, callback: anytype) Transform(@TypeOf(sender), c.Stored(@TypeOf(callback)), .stopped) {
    return .{ .sender = sender, .callback = callback };
}
