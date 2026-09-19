const ex = @import("zigexec");
const Handle = struct {
    pub fn call(_: @This(), _: anyerror) void {}
};
test {
    var scope: ex.SimpleCountingScope = .{};
    var loop: ex.RunLoop = .{};
    // Handling errors BEFORE scheduling leaves scheduling errors unhandled.
    try ex.spawn(ex.just(.{}).uponError(Handle, .{}).startsOn(loop.getScheduler()), scope.getToken(), .{});
}
