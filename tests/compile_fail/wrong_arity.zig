const ex = @import("zigexec");
const Add = struct {
    pub fn call(_: @This(), a: i64, b: i64) i64 {
        return a + b;
    }
};
test {
    _ = ex.just(42).then(Add, .{});
}
