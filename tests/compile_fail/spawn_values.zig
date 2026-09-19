const ex = @import("zigexec");
test {
    var scope: ex.SimpleCountingScope = .{};
    try ex.spawn(ex.just(.{42}), scope.getToken(), .{});
}
