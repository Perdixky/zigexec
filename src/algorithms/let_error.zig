const c = @import("../execution/protocol.zig");
const Let = @import("detail/let.zig").Let;
pub fn letError(sender: anytype, callback: anytype) Let(@TypeOf(sender), c.Stored(@TypeOf(callback)), .err) {
    return .{ .sender = sender, .callback = callback };
}
