const std = @import("std");
const protocol = @import("receiver.zig");
const Scope = @import("scope.zig").Scope;
const CompletionRef = @import("completion_ref.zig").CompletionRef;

/// Eagerly connect at the final address. Completion may destroy the connection;
/// owners may also retain it to keep borrowed result storage alive.
pub fn Connection(comptime S: type, comptime R: type) type {
    return struct {
        state: State,
        child: protocol.OperationOf(S, *State) = undefined,
        started: bool = false,
        const Self = @This();
        const State = struct {
            receiver: protocol.TypedReceiver(S.Values, R),
            scope: Scope = .{},
            completed: bool = false,
            pub fn getEnv(self: *@This()) protocol.EnvOf(R) {
                return self.receiver.getEnv().withScope(&self.scope);
            }
            fn complete(self: *@This(), result: CompletionRef(S.Values)) void {
                std.debug.assert(!self.completed);
                self.completed = true;
                const Forward = struct {
                    receiver: protocol.TypedReceiver(S.Values, R),
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
            std.debug.assert(!self.started);
            self.started = true;
            self.child.start(); // Tail: even synchronous completion may destroy self.
        }
    };
}
pub fn connectInto(out: anytype, sender: anytype, receiver: anytype) void {
    const checked: *Connection(@TypeOf(sender), @TypeOf(receiver)) = out;
    checked.* = .{ .state = .{ .receiver = .init(receiver) } };
    protocol.connectChild(&out.child, sender, &out.state);
}
pub const connect = connectInto;
pub fn start(operation: anytype) void {
    operation.start();
}
