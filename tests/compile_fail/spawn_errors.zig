const ex = @import("zigexec");
test {
    var scope: ex.CountingScope = .{};
    try ex.spawn(ex.justError(ex.Values(.{}), error.Unhandled), scope.getToken(), .{});
}
