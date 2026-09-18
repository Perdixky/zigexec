const ex = @import("zigexec");
test {
    _ = ex.just(.{}).repeatEffectUntil();
}
