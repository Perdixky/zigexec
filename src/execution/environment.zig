const std = @import("std");

/// Execution environment exposed through getEnv() and forwarded upstream.
/// When supplied, the allocator is borrowed and must outlive operations and owned
/// results. Concurrent branches require an allocator supporting concurrent use.
pub const Env = struct {
    allocator: ?std.mem.Allocator = null,
    start_scheduler: ?@import("../schedulers/start_scheduler.zig") = null,
    stop_token: @import("../cancellation/token.zig") = .{},

    /// Internal execution lifetime, propagated unchanged by ordinary nodes.
    scope: ?*@import("scope.zig").Scope = null,

    pub fn getStartScheduler(self: Env) error{MissingStartScheduler}!@import("../schedulers/start_scheduler.zig") {
        return self.start_scheduler orelse error.MissingStartScheduler;
    }

    pub fn withScope(self: Env, scope: *@import("scope.zig").Scope) Env {
        var result = self;
        result.scope = scope;
        return result;
    }

    /// Allocation is an optional environment service, with no global fallback.
    pub fn getAllocator(self: Env) error{MissingAllocator}!std.mem.Allocator {
        return self.allocator orelse error.MissingAllocator;
    }

    /// Override only cancellation, preserving all other execution services.
    pub fn withStopToken(self: Env, token: @import("../cancellation/token.zig")) Env {
        var result = self;
        result.stop_token = token;
        return result;
    }
};
