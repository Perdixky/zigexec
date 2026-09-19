const std = @import("std");
const ex = @import("../root.zig");
const traits = @import("../detail/completion_traits.zig");
const Empty = ex.Values(.{});

/// Eager, independently owned work. Explicit Env supplies allocation; scope
/// token supplies association/cancellation. Failure means sender never started.
/// ScopeClosed is a Zig extension to make rejected resource transfers visible.
pub fn spawn(sender: anytype, token: anytype, env: ex.Env) !void {
    const wrapped = token.wrap(sender);
    const S = @TypeOf(wrapped);
    if (S.Values != Empty) @compileError("zigexec.spawn: task must complete with no values; consume results with then first");
    if (comptime traits.canError(S)) @compileError("zigexec.spawn: sender may complete with error; handle errors with an infallible uponError or letError before spawning");
    const Association = @TypeOf(token.tryAssociate());
    const Node = struct {
        allocator: std.mem.Allocator,
        env: ex.Env,
        association: Association,
        operation: ex.Connection(S) = undefined,
        pub fn getEnv(self: *@This()) ex.Env {
            return self.env;
        }
        pub fn setValue(_: *@This(), _: *const Empty) void {}
        pub fn setStopped(_: *@This()) void {}
        pub fn setError(_: *@This(), err: anyerror) void {
            std.debug.panic("zigexec.spawn: sender violated can_error=false: {s}", .{@errorName(err)});
        }
        pub fn setFinished(self: *@This()) void {
            var association = self.association.take();
            self.allocator.destroy(self);
            association.deinit(); // Only after ALL uses of the allocator end.
        }
    };
    // Reserve first, so the allocator can itself be a scope-protected resource.
    var association = token.tryAssociate();
    if (!association.isEngaged()) return error.ScopeClosed;
    errdefer association.deinit();
    const allocator = try env.getAllocator();
    const node = try allocator.create(Node);
    var child_env = env;
    child_env.scope = null;
    node.* = .{ .allocator = allocator, .env = child_env, .association = association.take() };
    node.operation = ex.connect(wrapped, node);
    node.operation.start(); // May reclaim node inline.
}
