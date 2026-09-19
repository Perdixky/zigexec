const ex = @import("zigexec");
test {
    var scope: ex.CountingScope = .{};
    _ = ex.runInScope(&scope, ex.just(.{42}));
}
