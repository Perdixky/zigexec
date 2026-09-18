//! Bind a lexical expression to stored inputs, or sequence an already-constructed
//! sender. A concrete sender does not consume the predecessor's completion values.
const std = @import("std");
const c = @import("../../execution/protocol.zig");

fn isExpression(comptime Body: type) bool {
    return @typeInfo(Body) == .@"struct" and @hasDecl(Body, "__zigexec_expression");
}
fn NextSender(comptime Body: type, comptime Input: type) type {
    if (isExpression(Body)) return Body.Bound(Input);
    if (@typeInfo(Body) == .@"struct" and @hasDecl(Body, "Values") and @hasDecl(Body, "Operation") and @hasDecl(Body, "connect")) {
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
        const Self = @This();
        pub const Operation = struct {
            sender: S,
            body: Body,
            receiver: c.Receiver(Values),
            child: S.Operation = undefined,
            input: S.Values = undefined,
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
            pub fn setValue(self: *Op, values: S.Values) void {
                self.input = values;
                const next = if (comptime isExpression(Body)) self.body.bindInput(&self.input) else self.body;
                self.next = next.connect(self.receiver);
                self.next.start();
                // Completion may destroy self: do not touch it after start.
            }
            pub fn setError(self: *Op, err: anyerror) void {
                self.receiver.setError(err);
            }
            pub fn setStopped(self: *Op) void {
                self.receiver.setStopped();
            }
        };
        pub fn connect(self: Self, receiver: c.Receiver(Values)) Operation {
            return .{ .sender = self.sender, .body = self.body, .receiver = receiver };
        }
    };
}
