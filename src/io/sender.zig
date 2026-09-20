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
        pub fn Operation(comptime R: type) type {
            return struct {
                context: ContextPointer,
                description: request.Description,
                receiver: c.TypedReceiver(Values, R),
                output: Values = undefined,
                node: Context.Request = undefined,
                stop_callback: c.StopCallbackFor(R) = .{},
                started: bool = false,
                const Op = @This();
                pub fn start(self: *Op) void {
                    std.debug.assert(!self.started);
                    self.started = true;
                    self.node = .{ .description = self.description, .context = self, .complete = complete };
                    self.stop_callback.init(self.receiver.getEnv().stop_token, self, cancel);
                    self.context.submit(&self.node);
                }
                fn cancel(ctx: *anyopaque) void {
                    const self: *Op = @ptrCast(@alignCast(ctx));
                    self.context.cancel(&self.node);
                }
                fn complete(ctx: *anyopaque, result: request.Result) void {
                    const self: *Op = @ptrCast(@alignCast(ctx));
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
        }
        pub fn connectInto(self: Self, out: anytype, receiver: anytype) void {
            out.* = .{ .context = self.context, .description = self.description, .receiver = .init(receiver) };
        }
    };
}

pub fn make(comptime kind: request.Kind, context: anytype, description: request.Description) fluent.Sender(Sender(@TypeOf(context), kind)) {
    return fluent.asSender(Sender(@TypeOf(context), kind){ .context = context, .description = description });
}
