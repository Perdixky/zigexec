//! Inspect optimized IR: the actual receiver dispatch must not copy the payload.
const ex = @import("zigexec");
const Values = ex.Values(.{[65536]u8});
export fn forward(receiver: *const ex.Receiver(Values), values: *const Values) void {
    receiver.setValue(values);
}
