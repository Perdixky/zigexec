const s = @import("../sender.zig");
pub fn connect(context: anytype, fd: i32, address: *const @import("std").posix.sockaddr, length: @import("std").posix.socklen_t) @import("../types.zig").Connect(@TypeOf(context)) {
    return s.make(.connect, context, .{ .connect = .{ .fd = fd, .address = address, .length = length } });
}
