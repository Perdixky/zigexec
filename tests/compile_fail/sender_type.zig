const ex = @import("zigexec");
test "sender operands must be constructed values" {
    _ = ex.just(1).letValue(ex.Just(.{i64}), .{});
}
