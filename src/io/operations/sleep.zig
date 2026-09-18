const s = @import("../sender.zig");
pub fn sleepFor(context: anytype, nanoseconds: u64) @import("../types.zig").SleepFor(@TypeOf(context)) {
    return s.make(.sleep, context, .{ .sleep = nanoseconds });
}
