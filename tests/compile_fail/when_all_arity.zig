const ex = @import("zigexec");
const Wrong = struct {
    pub fn call(_: @This(), values: ex.Values(.{ i64, i64 })) i64 {
        return values[0] + values[1];
    }
};
test {
    _ = ex.whenAll(.{ ex.just(1), ex.just(2) }).then(Wrong, .{});
}
