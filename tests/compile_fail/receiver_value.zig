const std = @import("std");
const ex = @import("zigexec");
const Receiver = struct {
    pub fn getEnv(_: *@This()) ex.Env {
        return .{ .allocator = std.testing.allocator };
    }
    pub fn setValue(_: *@This(), _: ex.Values(.{i64})) void {}
    pub fn setError(_: *@This(), _: anyerror) void {}
    pub fn setStopped(_: *@This()) void {}
};
test "legacy by-value receiver requires explicit migration" {
    var receiver: Receiver = .{};
    var unstarted: ex.Connection(@TypeOf(ex.just(42)), @TypeOf(&receiver)) = undefined;
    ex.connectInto(&unstarted, ex.just(42), &receiver);
}
