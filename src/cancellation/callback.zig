//! Register in place; never move/copy a registered callback. init may invoke
//! immediately. deinit waits for a foreign invocation, but supports self-removal.
const std = @import("std");
const Source = @import("source.zig");
const Token = @import("token.zig");
const Callback = @This();

source: ?*Source = null,
context: *anyopaque = undefined,
function: *const fn (*anyopaque) void = undefined,
previous: ?*Callback = null,
next: ?*Callback = null,
linked: bool = false,
invocation: ?*Invocation = null,

pub const Invocation = struct {
    thread: std.Thread.Id,
    removed: bool = false,
};

pub fn init(self: *Callback, token: Token, context: *anyopaque, function: *const fn (*anyopaque) void) void {
    std.debug.assert(self.source == null);
    self.* = .{ .source = token.source, .context = context, .function = function };
    const source = token.source orelse return;
    source.mutex.lock();
    source.registrations += 1;
    if (source.requested.load(.acquire)) {
        source.invokeLocked(self);
    } else {
        self.next = source.head;
        if (source.head) |head| head.previous = self;
        source.head = self;
        self.linked = true;
    }
    source.mutex.unlock();
}

pub fn deinit(self: *Callback) void {
    const source = self.source orelse return;
    source.mutex.lock();
    defer source.mutex.unlock();
    if (self.linked) source.unlinkLocked(self);
    while (self.invocation) |invocation| {
        if (invocation.thread == std.Thread.getCurrentId()) {
            invocation.removed = true;
            break;
        }
        source.finished.waitForSignal(&source.mutex);
    }
    source.registrations -= 1;
    self.source = null;
    self.invocation = null;
}
