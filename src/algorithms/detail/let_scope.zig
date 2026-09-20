//! Bind a lexical expression to stored inputs, or sequence an already-constructed
//! sender. A concrete sender does not consume the predecessor's completion values.
const traits = @import("../../detail/completion_traits.zig");
const std = @import("std");
const c = @import("../../execution/protocol.zig");

fn isExpression(comptime Body: type) bool {
    return @typeInfo(Body) == .@"struct" and @hasDecl(Body, "__zigexec_expression");
}
fn NextSender(comptime Body: type, comptime Input: type) type {
    if (isExpression(Body)) return Body.Bound(Input);
    if (@typeInfo(Body) == .@"struct" and @hasDecl(Body, "Values") and @hasDecl(Body, "Operation") and (@hasDecl(Body, "connectInto") or @hasDecl(Body, "connect"))) {
        @import("../../detail/diagnostics.zig").requireSender(Body, Body, "letValue");
        return Body;
    }
    @compileError("zigexec.letValue: expected a sender or upstream() subchain");
}

pub fn Scope(comptime S: type, comptime Body: type) type {
    const Next = NextSender(Body, S.Values);
    return struct {
        sender: S,
        body: Body,
        pub const Values = Next.Values;
        pub const can_error = traits.canError(S) or traits.canError(Next);
        const Self = @This();
        pub fn Operation(comptime R: type) type {
            return struct {
                body: if (isExpression(Body)) Body else void,
                receiver: c.TypedReceiver(Values, R),
                child: c.OperationOf(S, *Op) = undefined,
                next: c.OperationOf(Next, c.TypedReceiver(Values, R)) = undefined,
                started: bool = false,
                next_connected: bool = false,
                const Op = @This();
                pub fn cleanup(self: *Op, continuation: anytype) void {
                    if (self.next_connected)
                        c.cleanupOperations(.{ &self.next, &self.child }, continuation)
                    else
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
                pub fn setValue(self: *Op, values: *const S.Values) void {
                    if (comptime isExpression(Body)) {
                        const next = self.body.bindInput(values);
                        c.connectChild(&self.next, next, self.receiver);
                    }
                    self.next_connected = true;
                    self.next.start();
                    // Input storage remains in child while its owner retains the operation.
                }
                pub fn setError(self: *Op, err: anyerror) void {
                    self.receiver.setError(err);
                }
                pub fn setStopped(self: *Op) void {
                    self.receiver.setStopped();
                }
            };
        }
        pub fn connectInto(self: Self, out: anytype, receiver: anytype) void {
            out.* = .{ .body = if (comptime isExpression(Body)) self.body else {}, .receiver = .init(receiver) };
            c.connectChild(&out.child, self.sender, out);
            if (comptime !isExpression(Body)) {
                c.connectChild(&out.next, self.body, out.receiver);
                out.next_connected = true;
            }
        }
    };
}
