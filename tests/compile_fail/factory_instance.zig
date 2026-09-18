const ex = @import("zigexec");
const Factory = struct {
    pub fn call(_: @This(), n: i64) ex.Just(.{i64}) {
        return ex.just(n);
    }
};
test "factory identity is passed as a type" {
    _ = ex.just(42).letValue(Factory{}, .{});
}
