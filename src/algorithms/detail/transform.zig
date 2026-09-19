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
        const Self = @This();
        pub const Operation = struct {
            sender: S,
            callback: F,
            receiver: c.Receiver(V),
            output: V = undefined,
            child: S.Operation = undefined,
            started: bool = false,
            const Op = @This();
            pub fn start(self: *Op) void {
                std.debug.assert(!self.started);
                self.started = true;
                self.child = self.sender.connect(c.Receiver(S.Values).init(self));
                self.child.start();
            }
            pub fn getEnv(self: *Op) c.Env {
                return self.receiver.env;
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
        pub fn connect(self: Self, receiver: c.Receiver(V)) Operation {
            return .{ .sender = self.sender, .callback = self.callback, .receiver = receiver };
        }
    };
}
