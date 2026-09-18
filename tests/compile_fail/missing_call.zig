const ex = @import("zigexec");
const Empty = struct {};
test {
    _ = ex.just(42).then(Empty, .{});
}
