const ex = @import("zigexec");
const Offset = struct {
    offset: i64,
    pub fn call(self: @This(), n: i64) i64 {
        return n + self.offset;
    }
};
test {
    _ = ex.just(42).then(Offset, .{});
}
