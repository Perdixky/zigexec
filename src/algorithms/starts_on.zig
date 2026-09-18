const schedule = @import("../execution/schedule.zig").schedule;
fn StartCallback(comptime S: type) type {
    return struct {
        sender: S,
        pub fn call(self: @This()) S {
            return self.sender;
        }
    };
}

pub fn StartsOn(comptime Scheduler: type, comptime S: type) type {
    return @import("detail/let.zig").Let(@TypeOf(schedule(@as(Scheduler, undefined))), StartCallback(S), .value);
}
pub fn startsOn(scheduler: anytype, sender: anytype) StartsOn(@TypeOf(scheduler), @TypeOf(sender)) {
    return .{ .sender = schedule(scheduler), .callback = .{ .sender = sender } };
}
