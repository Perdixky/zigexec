const ex = @import("zigexec");
const Length = struct {
    pub fn call(_: @This(), text: []const u8) usize {
        return text.len;
    }
};
test {
    _ = ex.just(42).then(Length, .{});
}
