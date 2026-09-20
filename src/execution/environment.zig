const std = @import("std");
const StopToken = @import("../cancellation/token.zig");
pub const NeverStopToken = struct {
    pub fn stopRequested(_: @This()) bool {
        return false;
    }
    pub fn stopPossible(_: @This()) bool {
        return false;
    }
};
/// Runtime-compatible environment, including an optional stoppable token.
pub const Env = Environment(StopToken);
/// Statically unstoppable environment. Callback storage and checks compile away.
pub const UnstoppableEnv = Environment(NeverStopToken);
pub fn Environment(comptime Token: type) type {
    return struct {
        allocator: ?std.mem.Allocator = null,
        start_scheduler: ?@import("../schedulers/start_scheduler.zig") = null,
        stop_token: Token = .{},
        /// Optional cleanup registry for resource associations; never a work counter.
        scope: ?*@import("scope.zig").Scope = null,
        const Self = @This();
        pub fn getStartScheduler(self: Self) error{MissingStartScheduler}!@import("../schedulers/start_scheduler.zig") {
            return self.start_scheduler orelse error.MissingStartScheduler;
        }
        pub fn withScope(self: Self, scope: *@import("scope.zig").Scope) Self {
            var result = self;
            result.scope = scope;
            return result;
        }
        pub fn getAllocator(self: Self) error{MissingAllocator}!std.mem.Allocator {
            return self.allocator orelse error.MissingAllocator;
        }
        pub fn withStopToken(self: Self, token: anytype) Environment(if (@TypeOf(token) == NeverStopToken) NeverStopToken else StopToken) {
            return .{ .allocator = self.allocator, .start_scheduler = self.start_scheduler, .stop_token = canonicalToken(token), .scope = self.scope };
        }
        pub fn toDynamic(self: Self) Env {
            return .{ .allocator = self.allocator, .start_scheduler = self.start_scheduler, .stop_token = if (Token == NeverStopToken) .{} else self.stop_token, .scope = self.scope };
        }
    };
}
/// Struct-literal convenience retains a static never-stop token when omitted.
pub fn Normalize(comptime E: type) type {
    return Environment(if (!@hasField(E, "stop_token") or @FieldType(E, "stop_token") == NeverStopToken) NeverStopToken else StopToken);
}
pub fn normalize(env: anytype) Normalize(@TypeOf(env)) {
    const E = @TypeOf(env);
    inline for (@typeInfo(E).@"struct".field_names) |name| {
        if (!@hasField(Normalize(E), name)) @compileError("zigexec: unknown environment field: " ++ name);
    }
    var result: Normalize(E) = .{};
    inline for (.{ "allocator", "start_scheduler", "stop_token", "scope" }) |name| {
        if (@hasField(E, name)) {
            @field(result, name) = if (comptime std.mem.eql(u8, name, "stop_token")) canonicalToken(env.stop_token) else @field(env, name);
        }
    }
    return result;
}

fn canonicalToken(token: anytype) if (@TypeOf(token) == NeverStopToken) NeverStopToken else StopToken {
    const T = @TypeOf(token);
    if (T == NeverStopToken or T == StopToken) return token;
    // Preserve the old typed-argument convenience for anonymous token literals.
    inline for (@typeInfo(T).@"struct".field_names) |name| {
        if (comptime !std.mem.eql(u8, name, "source")) @compileError("zigexec: unknown stop token field: " ++ name);
    }
    return .{ .source = if (@hasField(T, "source")) token.source else null };
}
