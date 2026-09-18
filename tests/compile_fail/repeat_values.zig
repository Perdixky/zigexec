const ex = @import("zigexec");
test {
    _ = ex.just(42).repeatEffect();
}
