const s = @import("../sender.zig");
pub fn openAt(context: anytype, dir: i32, path: [:0]const u8, flags: u32, mode: u32) @import("../types.zig").OpenAt(@TypeOf(context)) {
    return s.make(.open_at, context, .{ .open_at = .{ .dir = dir, .path = path, .flags = flags, .mode = mode } });
}
