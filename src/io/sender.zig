const std = @import("std");
const StartGuard = @import("../detail/start_guard.zig").StartGuard;
const c = @import("../execution/protocol.zig");
const request = @import("request.zig");
const fluent = @import("../execution/sender.zig");

/// Context protocol: associated Request with description/context/complete fields
/// (plus an optional `cancellable: bool` hint, set when the stop token can fire);
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
                receiver: c.TypedReceiver(Values, R),
                output: Values = undefined,
                // Built once at connect (the final address); holds the only
                // copy of the description, so start touches no extra storage.
                node: Context.Request,
                stop_callback: c.StopCallbackFor(R) = .{},
                started: StartGuard = .{},
                const Op = @This();
                pub fn start(self: *Op) void {
                    self.started.begin();
                    const stop_token = self.receiver.getEnv().stop_token;
                    if (comptime @hasField(Context.Request, "cancellable")) self.node.cancellable = stop_token.stopPossible();
                    self.stop_callback.init(stop_token, self, cancel);
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
            out.* = .{
                .context = self.context,
                .receiver = .init(receiver),
                .node = .{ .description = self.description, .context = out, .complete = @TypeOf(out.*).complete },
            };
        }
    };
}

pub fn make(comptime kind: request.Kind, context: anytype, description: request.Description) fluent.Sender(Sender(@TypeOf(context), kind)) {
    return fluent.asSender(Sender(@TypeOf(context), kind){ .context = context, .description = description });
}
