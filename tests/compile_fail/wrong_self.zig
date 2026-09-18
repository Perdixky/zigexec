const ex = @import("zigexec");
const Wrong = struct {
    pub fn call(_: usize, n: i64) i64 {
        return n;
    }
};
test {
    _ = ex.just(42).then(Wrong, .{});
}
