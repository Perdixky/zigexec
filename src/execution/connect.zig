const std = @import("std");
const StartGuard = @import("../detail/start_guard.zig").StartGuard;
const receiver = @import("receiver.zig");
const Scope = @import("scope.zig").Scope;
const CompletionRef = @import("completion_ref.zig").CompletionRef;

/// Eagerly connect at the final address. Completion may destroy the connection;
/// owners may also retain it to keep borrowed result storage alive.
pub fn Connection(comptime S: type, comptime R: type) type {
    return struct {
        state: State,
        child: receiver.OperationOf(S, *State) = undefined,
        started: StartGuard = .{},
        const Self = @This();
        pub fn cleanup(self: *Self, continuation: anytype) void {
            @import("cleanup.zig").cleanupOperation(&self.child, continuation);
        }
        const State = struct {
            receiver: receiver.TypedReceiver(S.Values, R),
            scope: Scope = .{},
            completed: bool = false,
            pub fn getEnv(self: *@This()) receiver.EnvOf(R) {
                return self.receiver.getEnv().withScope(&self.scope);
            }
            fn complete(self: *@This(), result: CompletionRef(S.Values)) void {
                std.debug.assert(!self.completed);
                self.completed = true;
                const Forward = struct {
                    receiver: receiver.TypedReceiver(S.Values, R),
                    result: CompletionRef(S.Values),
                    pub fn run(action: @This()) void {
                        action.receiver.completeRef(action.result);
                    }
                };
                self.scope.complete(Forward{ .receiver = self.receiver, .result = result });
            }
            pub fn setValue(self: *@This(), values: *const S.Values) void {
                self.complete(.{ .value = values });
            }
            pub fn setError(self: *@This(), err: anyerror) void {
                self.complete(.{ .err = err });
            }
            pub fn setStopped(self: *@This()) void {
                self.complete(.stopped);
            }
        };
        pub fn start(self: *Self) void {
            self.started.begin();
            self.child.start(); // Tail: even synchronous completion may destroy self.
        }
    };
}
pub fn connectInto(out: anytype, s: anytype, r: anytype) void {
    const checked: *Connection(@TypeOf(s), @TypeOf(r)) = out;
    checked.* = .{ .state = .{ .receiver = .init(r) } };
    receiver.connectChild(&out.child, s, &out.state);
}
pub const connect = connectInto;
pub fn start(operation: anytype) void {
    operation.start();
}
