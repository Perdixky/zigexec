const std = @import("std");
const c = @import("../execution/protocol.zig");
const request = @import("request.zig");
const fluent = @import("../execution/sender.zig");

/// Context protocol: associated Request with description/context/complete fields;
/// submit(*Request) and cancel(*Request), both thread-safe, infallible, nonblocking.
/// Backend signals exactly once, only after the OS releases all borrowed memory.
pub fn Sender(comptime ContextPointer: type, comptime kind: request.Kind) type {
    const Context = @typeInfo(ContextPointer).pointer.child;
    return struct {
        context: ContextPointer,
        description: request.Description,
        pub const Values = request.Values(kind);
        const Self = @This();
        pub const Operation = struct {
            context: ContextPointer,
            description: request.Description,
            receiver: c.Receiver(Values),
            output: Values = undefined,
            node: Context.Request = undefined,
            stop_callback: c.StopCallback = .{},
            started: bool = false,
            const Op = @This();
            pub fn start(self: *Op) void {
                std.debug.assert(!self.started);
                self.started = true;
                self.node = .{ .description = self.description, .context = self, .complete = complete };
                self.stop_callback.init(self.receiver.env.stop_token, self, cancel);
                c.Scope.acquire(self.receiver.env.scope);
                self.context.submit(&self.node);
            }
            fn cancel(ctx: *anyopaque) void {
                const self: *Op = @ptrCast(@alignCast(ctx));
                const scope = self.receiver.env.scope;
                c.Scope.acquire(scope);
                defer c.Scope.release(scope);
                self.context.cancel(&self.node);
            }
            fn complete(ctx: *anyopaque, result: request.Result) void {
                const self: *Op = @ptrCast(@alignCast(ctx));
                const scope = self.receiver.env.scope;
                defer c.Scope.release(scope);
                self.stop_callback.deinit();
                const receiver = self.receiver;
                switch (result) {
                    .value => |value| {
                        self.output = switch (kind) {
                            .read, .write, .recv, .send => .{value},
                            .open_at, .accept => .{@as(request.Handle, @intCast(value))},
                            else => .{},
                        };
                        receiver.setValue(&self.output);
                    },
                    .err => |err| receiver.setError(err),
                    .stopped => receiver.setStopped(),
                }
            }
        };
        pub fn connect(self: Self, receiver: c.Receiver(Values)) Operation {
            return .{ .context = self.context, .description = self.description, .receiver = receiver };
        }
    };
}

pub fn make(comptime kind: request.Kind, context: anytype, description: request.Description) fluent.Sender(Sender(@TypeOf(context), kind)) {
    return fluent.asSender(Sender(@TypeOf(context), kind){ .context = context, .description = description });
}
