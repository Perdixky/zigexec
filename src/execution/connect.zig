const Receiver = @import("receiver.zig").Receiver;
pub fn connect(sender: anytype, receiver: anytype) @TypeOf(sender).Operation {
    return sender.connect(Receiver(@TypeOf(sender).Values).init(receiver));
}

pub fn start(operation: anytype) void {
    operation.start();
}
