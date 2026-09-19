//! SimpleCountingScope plus cooperative cancellation. Stop does not close.
const ex = @import("../root.zig");
const Simple = @import("simple_counting_scope.zig");
const Self = @This();
counting: Simple = .{},
stop: ex.StopSource = .{},
pub const max_associations = Simple.max_associations;
pub const Association = Simple.Association;
pub const Join = Simple.Join;
pub const Token = struct {
    scope: *Self,
    pub fn wrap(self: @This(), sender: anytype) ex.WithStopToken(@TypeOf(sender)) {
        return ex.withStopToken(sender, self.scope.stop.token());
    }
    pub fn tryAssociate(self: @This()) Association {
        return self.scope.counting.getToken().tryAssociate();
    }
};
pub fn getToken(self: *Self) Token {
    return .{ .scope = self };
}
pub fn close(self: *Self) void {
    self.counting.close();
}
pub fn join(self: *Self) Join {
    return self.counting.join();
}
pub fn requestStop(self: *Self) bool {
    self.counting.beginDispatch();
    const requested = self.stop.requestStop();
    self.counting.endDispatch(); // Last access; a join may destroy this scope.
    return requested;
}
pub fn deinit(self: *Self) void {
    self.stop.deinit();
    self.counting.deinit();
}
