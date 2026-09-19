const ex = @import("zigexec");
const Handle = struct {
    pub fn call(_: @This(), err: anyerror) anyerror!void {
        return err;
    }
};
test {
    var scope: ex.SimpleCountingScope = .{};
    try ex.spawn(ex.justError(ex.Values(.{}), error.Unhandled).uponError(Handle, .{}), scope.getToken(), .{});
}
