const ex = @import("zigexec");
test "sender values cannot receive captures" {
    _ = ex.just(1).letValue(ex.just(42), .{2});
}
