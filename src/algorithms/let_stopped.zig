const c = @import("../execution/protocol.zig");
const Let = @import("detail/let.zig").Let;
pub fn letStopped(sender: anytype, callback: anytype) Let(@TypeOf(sender), c.Stored(@TypeOf(callback)), .stopped) {
    return .{ .sender = sender, .callback = callback };
}
