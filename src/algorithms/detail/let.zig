const traits = @import("../../detail/completion_traits.zig");
const std = @import("std");
const c = @import("../../execution/protocol.zig");
pub const Channel = enum { value, err, stopped };
pub fn Let(comptime S: type, comptime F: type, comptime channel: Channel) type {
    const Args = switch (channel) {
        .value => S.Values,
        .err => @Tuple(&.{anyerror}),
        .stopped => @Tuple(&.{}),
    };
    const stage = switch (channel) {
        .value => "letValue",
        .err => "letError",
        .stopped => "letStopped",
    };
    const Next = c.Payload(c.CheckedResult(F, Args, stage));
    @import("../../detail/diagnostics.zig").requireSender(Next, F, stage);
    const V = Next.Values;
    if (channel != .value and V != S.Values)
        @compileError("recovery sender must have the same Values tuple as the original sender");
    return struct {
        sender: S,
        callback: F,
        pub const Values = V;
        pub const can_error = (channel != .err and traits.canError(S)) or traits.fallible(c.CheckedResult(F, Args, stage)) or traits.canError(Next);
        const Self = @This();
        pub fn Operation(comptime R: type) type {
            return struct {
                callback: F,
                receiver: c.TypedReceiver(V, R),
                child: c.OperationOf(S, *Op) = undefined,
                next: c.OperationOf(Next, c.TypedReceiver(V, R)) = undefined,
                started: bool = false,
                const Op = @This();
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
                    const sender = if (comptime @typeInfo(@TypeOf(result)) == .error_union)
                        result catch |err| return self.receiver.setError(err)
                    else
                        result;
                    c.connectChild(&self.next, sender, self.receiver);
                    self.next.start();
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
