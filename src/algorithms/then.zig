const c = @import("../execution/protocol.zig");
const Transform = @import("detail/transform.zig").Transform;
pub fn then(sender: anytype, callback: anytype) Transform(@TypeOf(sender), c.Stored(@TypeOf(callback)), .value) {
    return .{ .sender = sender, .callback = callback };
}
