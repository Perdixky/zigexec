//! Inspect optimized IR: the actual receiver dispatch must not copy the payload.
const ex = @import("zigexec");
const Values = ex.Values(.{[65536]u8});
export fn forward(receiver: *const ex.TypedReceiver(Values, *ForwardTarget), values: *const Values) void {
    receiver.setValue(values);
}
const ForwardTarget = struct {
    pub fn getEnv(_: *@This()) ex.Env {
        return .{};
    }
    pub fn setValue(_: *@This(), _: *const Values) void {}
    pub fn setError(_: *@This(), _: anyerror) void {}
    pub fn setStopped(_: *@This()) void {}
};
