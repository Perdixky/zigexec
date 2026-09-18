const ex = @import("zigexec");
const Number = struct {
    pub fn call(_: @This(), n: i64) i64 {
        return n;
    }
};
test {
    _ = ex.just(42).letValue(Number, .{});
}
