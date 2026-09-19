const std = @import("std");
const Receiver = @import("receiver.zig").Receiver;
const Env = @import("environment.zig").Env;
const Scope = @import("scope.zig").Scope;

/// Root execution owner. Keep its address stable from start until setFinished.
/// setValue/error/stopped publish completion; setFinished authorizes reclamation.
pub fn Connection(comptime S: type) type {
    return struct {
        sender: S,
        receiver: Receiver(S.Values),
        child: S.Operation = undefined,
        scope: Scope = .{ .on_idle = finished },
        started: bool = false,
        completed: bool = false,
        const Self = @This();
        pub fn start(self: *Self) void {
            std.debug.assert(!self.started);
            self.started = true;
            self.scope.context = self;
            // A public connection starts an independent root. Internal nodes
            // forward its scope; a borrowed Env is not ownership of another root.
            self.scope.enter();
            self.child = self.sender.connect(Receiver(S.Values).init(self));
            self.child.start();
            self.scope.leave();
        }
        pub fn getEnv(self: *Self) Env {
            return self.receiver.env.withScope(&self.scope);
        }
        pub fn setValue(self: *Self, values: *const S.Values) void {
            std.debug.assert(!self.completed);
            self.completed = true;
            self.receiver.setValue(values);
        }
        pub fn setError(self: *Self, err: anyerror) void {
            std.debug.assert(!self.completed);
            self.completed = true;
            self.receiver.setError(err);
        }
        pub fn setStopped(self: *Self) void {
            std.debug.assert(!self.completed);
            self.completed = true;
            self.receiver.setStopped();
        }
        fn finished(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            std.debug.assert(self.completed); // An async sender must acquire a scope entry.
            self.receiver.setFinished();
        }
    };
}

pub fn connect(sender: anytype, receiver: anytype) Connection(@TypeOf(sender)) {
    return .{ .sender = sender, .receiver = Receiver(@TypeOf(sender).Values).init(receiver) };
}
pub fn start(operation: anytype) void {
    operation.start();
}
