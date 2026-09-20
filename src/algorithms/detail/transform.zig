const traits = @import("../../detail/completion_traits.zig");
const std = @import("std");
const c = @import("../../execution/protocol.zig");
pub const Channel = enum { value, err, stopped };
pub fn Transform(comptime S: type, comptime F: type, comptime channel: Channel) type {
    const Args = switch (channel) {
        .value => S.Values,
        .err => @Tuple(&.{anyerror}),
        .stopped => @Tuple(&.{}),
    };
    const stage = switch (channel) {
        .value => "then",
        .err => "uponError",
        .stopped => "uponStopped",
    };
    const V = c.ReturnedValues(c.CheckedResult(F, Args, stage));
    if (channel != .value and V != S.Values)
        @compileError("recovery callback must return the sender's success type (or void for an empty tuple)");
    return struct {
        sender: S,
        callback: F,
        pub const Values = V;
        pub const can_error = (channel != .err and traits.canError(S)) or traits.fallible(c.CheckedResult(F, Args, stage));
        const Self = @This();
        pub fn Operation(comptime R: type) type {
            return struct {
                callback: F,
                receiver: c.TypedReceiver(V, R),
                output: V = undefined,
                child: c.OperationOf(S, *Op) = undefined,
                started: bool = false,
                const Op = @This();
                pub fn cleanup(self: *Op, continuation: anytype) void {
                    c.cleanupOperation(&self.child, continuation);
                }
                pub fn start(self: *Op) void {
                    std.debug.assert(!self.started);
                    self.started = true;
                    self.child.start();
                }
                pub fn getEnv(self: *Op) c.EnvOf(R) {
                    return self.receiver.getEnv();
                }
                fn apply(self: *Op, args: anytype) void {
                    const result = c.invokeStored(&self.callback, args);
                    if (comptime @typeInfo(@TypeOf(result)) == .error_union) {
                        const value = result catch |err| return self.receiver.setError(err);
                        self.output = c.resultValues(value);
                    } else {
                        self.output = c.resultValues(result);
                    }
                    self.receiver.setValue(&self.output);
                }
                pub fn setValue(self: *Op, values: *const S.Values) void {
                    if (channel == .value) self.apply(values.*) else self.receiver.setValue(values);
                }
                pub fn setError(self: *Op, err: anyerror) void {
                    if (channel == .err) self.apply(.{err}) else self.receiver.setError(err);
                }
                pub fn setStopped(self: *Op) void {
                    if (channel == .stopped) self.apply(.{}) else self.receiver.setStopped();
                }
            };
        }
        pub fn connectInto(self: Self, out: anytype, receiver: anytype) void {
            out.* = .{ .callback = self.callback, .receiver = .init(receiver) };
            c.connectChild(&out.child, self.sender, out);
        }
    };
}
