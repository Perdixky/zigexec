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
        const Self = @This();
        pub const Operation = struct {
            sender: S,
            callback: F,
            receiver: c.Receiver(V),
            input: Args = undefined,
            child: S.Operation = undefined,
            next: Next.Operation = undefined,
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
                self.input = args;
                const result = c.invokeStored(&self.callback, self.input);
                const sender = if (comptime @typeInfo(@TypeOf(result)) == .error_union)
                    result catch |err| return self.receiver.setError(err)
                else
                    result;
                self.next = sender.connect(self.receiver);
                self.next.start();
            }
            pub fn setValue(self: *Op, values: S.Values) void {
                if (channel == .value) self.apply(values) else self.receiver.setValue(values);
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
