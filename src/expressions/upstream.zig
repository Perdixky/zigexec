const ex = @import("../root.zig");
const Expression = @import("chain.zig").Expression;

/// Borrow the nearest letValue scope's completion storage without rebuilding a
/// just sender. Business callbacks keep their declared argument types.
pub fn upstream() Expression(Input) {
    return .{ .inner = .{} };
}

const Input = struct {
    pub fn Bound(comptime Values: type) type {
        return ex.Sender(Borrowed(Values));
    }
    pub fn bindInput(_: @This(), input: anytype) Bound(@typeInfo(@TypeOf(input)).pointer.child) {
        return ex.asSender(Borrowed(@typeInfo(@TypeOf(input)).pointer.child){ .input = input });
    }
};

// Internal view: its owner is the enclosing operation tree, never a stack tuple.
fn Borrowed(comptime V: type) type {
    return struct {
        input: *const V,
        pub const Values = V;
        pub const Operation = struct {
            input: *const V,
            receiver: ex.Receiver(V),
            pub fn start(self: *@This()) void {
                self.receiver.setValue(self.input);
            }
        };
        pub fn connect(self: @This(), receiver: ex.Receiver(V)) Operation {
            return .{ .input = self.input, .receiver = receiver };
        }
    };
}
