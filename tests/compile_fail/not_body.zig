const ex = @import("zigexec");
test {
    _ = ex.just(42).letValue(123, .{});
}
