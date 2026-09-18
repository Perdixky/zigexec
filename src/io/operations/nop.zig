const s = @import("../sender.zig");
pub fn schedule(context: anytype) @import("../types.zig").Schedule(@TypeOf(context)) {
    return s.make(.nop, context, .nop);
}
