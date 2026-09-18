const ex = @import("zigexec");
const Receiver = struct {
    pub fn setValue(_: *@This(), _: ex.Values(.{i64})) void {}
    pub fn setError(_: *@This(), _: anyerror) void {}
    pub fn setStopped(_: *@This()) void {}
};
test {
    var receiver: Receiver = .{};
    _ = ex.connect(ex.just(42), &receiver);
}
