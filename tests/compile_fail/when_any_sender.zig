const ex = @import("zigexec");
test {
    _ = ex.whenAny(.{ .invalid = @as(i64, 42) });
}
