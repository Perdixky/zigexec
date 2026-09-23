const std = @import("std");
const StartGuard = @import("../../detail/start_guard.zig").StartGuard;
const ex = @import("../../root.zig");
const io = @import("../root.zig");
const Task = @import("../../detail/task.zig").Task;

/// Send the complete slice, retrying short sends. Storage remains borrowed until
/// completion. An error/stop can occur after a prefix has already been sent.
pub fn SendAll(comptime Context: type) type {
    return struct {
        context: Context,
        fd: i32,
        buffer: []const u8,
        flags: u32,
        pub const Values = ex.Values(.{usize});
        const Self = @This();
        pub fn Operation(comptime R: type) type {
            return struct {
                sender: Self,
                receiver: ex.TypedReceiver(Values, R),
                offset: usize = 0,
                output: Values = .{0},
                send: ex.meta.OperationOf(io.Send(Context), *Op) = undefined,
                // A short send resumes through the trampoline: backends that complete
                // inline cannot grow the stack, and stop is observed between sends.
                resume_task: Task = .{ .run = resumeSend },
                started: StartGuard = .{},
                const Op = @This();
                // The send child is a plain source, so there is nothing to clean up
                // before this storage is reused (and it may never be connected).
                comptime {
                    std.debug.assert(!@hasDecl(@FieldType(Op, "send"), "cleanup"));
                }
                fn resumeSend(task: *Task) void {
                    const self: *Op = @fieldParentPtr("resume_task", task);
                    if (self.receiver.getEnv().stop_token.stopRequested()) return self.receiver.setStopped();
                    self.issue();
                }
                pub fn start(self: *Op) void {
                    self.started.begin();
                    if (self.receiver.getEnv().stop_token.stopRequested()) return self.receiver.setStopped();
                    if (self.sender.buffer.len == 0) return self.receiver.setValue(&self.output);
                    self.issue();
                }
                fn issue(self: *Op) void {
                    const s = self.sender;
                    @import("../../execution/protocol.zig").connectChild(&self.send, io.send(s.context, s.fd, s.buffer[self.offset..], s.flags), self);
                    self.send.start(); // Completion may reconnect send or destroy self.
                }
                pub fn getEnv(self: *Op) ex.EnvOf(R) {
                    return self.receiver.getEnv();
                }
                pub fn setValue(self: *Op, values: *const io.Send(Context).Values) void {
                    const count = values[0];
                    if (count == 0) return self.receiver.setError(error.WriteZero);
                    std.debug.assert(count <= self.sender.buffer.len - self.offset);
                    self.offset += count;
                    if (self.offset == self.sender.buffer.len) {
                        self.output = .{self.offset};
                        return self.receiver.setValue(&self.output);
                    }
                    (ex.TrampolineScheduler{}).submit(&self.resume_task) catch |err| switch (err) {};
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
            out.* = .{ .sender = self, .receiver = .init(receiver) };
        }
    };
}

pub fn sendAll(context: anytype, fd: i32, buffer: []const u8, flags: u32) ex.Sender(SendAll(@TypeOf(context))) {
    return ex.asSender(SendAll(@TypeOf(context)){ .context = context, .fd = fd, .buffer = buffer, .flags = flags });
}
