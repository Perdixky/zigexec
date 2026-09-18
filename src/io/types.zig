const fluent = @import("../execution/sender.zig");
const RawSender = @import("sender.zig").Sender;
pub fn ReadSome(comptime Context: type) type {
    return fluent.Sender(RawSender(Context, .read));
}
pub fn WriteSome(comptime Context: type) type {
    return fluent.Sender(RawSender(Context, .write));
}
pub fn Recv(comptime Context: type) type {
    return fluent.Sender(RawSender(Context, .recv));
}
pub fn Send(comptime Context: type) type {
    return fluent.Sender(RawSender(Context, .send));
}
pub fn SleepFor(comptime Context: type) type {
    return fluent.Sender(RawSender(Context, .sleep));
}
pub fn OpenAt(comptime Context: type) type {
    return fluent.Sender(RawSender(Context, .open_at));
}
pub fn Close(comptime Context: type) type {
    return fluent.Sender(RawSender(Context, .close));
}
pub fn Fsync(comptime Context: type) type {
    return fluent.Sender(RawSender(Context, .fsync));
}
pub fn Accept(comptime Context: type) type {
    return fluent.Sender(RawSender(Context, .accept));
}
pub fn Connect(comptime Context: type) type {
    return fluent.Sender(RawSender(Context, .connect));
}
pub fn Schedule(comptime Context: type) type {
    return fluent.Sender(RawSender(Context, .nop));
}

pub fn SendAll(comptime Context: type) type {
    return @import("../root.zig").Sender(@import("operations/send_all.zig").SendAll(Context));
}
