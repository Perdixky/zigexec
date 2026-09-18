const ex = @import("zigexec");
test "sender args must be an empty initializer" {
    _ = ex.just(1).letValue(ex.just(42), false);
}
