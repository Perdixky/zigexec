const ex = @import("zigexec");
test "unbound expressions reject misplaced captures before binding" {
    _ = ex.upstream().letValue(ex.upstream(), .{ .offset = 2 });
}
