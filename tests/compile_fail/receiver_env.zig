const ex = @import("zigexec");
const Receiver = struct {
    pub fn setValue(_: *@This(), _: *const ex.Values(.{i64})) void {}
    pub fn setError(_: *@This(), _: anyerror) void {}
    pub fn setStopped(_: *@This()) void {}
};
test {
    var receiver: Receiver = .{};
    var unstarted: ex.Connection(@TypeOf(ex.just(42)), @TypeOf(&receiver)) = undefined;
    ex.connectInto(&unstarted, ex.just(42), &receiver);
}
