const std = @import("std");

/// Execution environment exposed through getEnv() and forwarded upstream.
/// The allocator is borrowed: its lifetime must cover operations and any owned
/// results. Concurrent branches require an allocator supporting concurrent use.
pub const Env = struct {
    allocator: std.mem.Allocator,
    stop_token: @import("../cancellation/token.zig") = .{},

    pub fn getAllocator(self: Env) std.mem.Allocator {
        return self.allocator;
    }

    /// Override only cancellation, preserving all other execution services.
    pub fn withStopToken(self: Env, token: @import("../cancellation/token.zig")) Env {
        var result = self;
        result.stop_token = token;
        return result;
    }
};
