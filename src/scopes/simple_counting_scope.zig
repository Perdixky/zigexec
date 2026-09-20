//! Association counting only: no allocation, scheduler ownership, or error policy.
const std = @import("std");
const ex = @import("../root.zig");
const sync = @import("../detail/sync.zig");
const Self = @This();
const Empty = ex.Values(.{});

pub const State = enum { unused, open, closed, open_and_joining, closed_and_joining, unused_and_closed, joined };
pub const max_associations = std.math.maxInt(usize);
mutex: sync.Mutex = .{},
state: State = .unused,
count: usize = 0,
// Cancellation dispatch must finish before its stop source can be destroyed.
// These internal guards do not create user-visible scope associations.
dispatches: usize = 0,
waiters: ?*Waiter = null,

pub fn deinit(self: *Self) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    std.debug.assert(self.count == 0 and self.dispatches == 0 and self.waiters == null);
    std.debug.assert(self.state == .unused or self.state == .unused_and_closed or self.state == .joined);
}

pub const Association = struct {
    scope: ?*Self = null,
    pub fn isEngaged(self: @This()) bool {
        return self.scope != null;
    }
    /// Explicit ownership transfer: ordinary assignment is NOT a clone.
    pub fn take(self: *@This()) @This() {
        const result = self.*;
        self.* = .{};
        return result;
    }
    pub fn tryAssociate(self: @This()) @This() {
        return if (self.scope) |scope| scope.tryAssociate() else .{};
    }
    /// Transfer to a release action usable after operation storage is freed.
    pub fn takeReleaseAction(self: *@This()) ex.Scope.ReleaseAction {
        const scope = self.scope orelse return .{};
        self.scope = null;
        return .{ .context = scope, .release_fn = releaseErased };
    }
    fn releaseErased(context: *anyopaque) void {
        const scope: *Self = @ptrCast(@alignCast(context));
        scope.release();
    }
    pub fn deinit(self: *@This()) void {
        const scope = self.scope orelse return;
        self.scope = null;
        scope.release();
    }
};
pub const Token = struct {
    scope: *Self,
    pub fn wrap(_: @This(), sender: anytype) @TypeOf(sender) {
        return sender;
    }
    pub fn tryAssociate(self: @This()) Association {
        return self.scope.tryAssociate();
    }
};
pub fn getToken(self: *Self) Token {
    return .{ .scope = self };
}

fn tryAssociate(self: *Self) Association {
    self.mutex.lock();
    defer self.mutex.unlock();
    if (self.count == max_associations) return .{};
    switch (self.state) {
        .unused => self.state = .open,
        .open, .open_and_joining => {},
        else => return .{},
    }
    self.count += 1;
    return .{ .scope = self };
}
pub fn close(self: *Self) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.state = switch (self.state) {
        .unused => .unused_and_closed,
        .open => .closed,
        .open_and_joining => .closed_and_joining,
        else => self.state,
    };
}
fn release(self: *Self) void {
    self.mutex.lock();
    std.debug.assert(self.count != 0);
    self.count -= 1;
    const waiters = self.detachReadyLocked();
    self.mutex.unlock();
    notify(waiters); // May destroy self. No further scope access.
}
fn detachReadyLocked(self: *Self) ?*Waiter {
    if (self.count != 0 or self.dispatches != 0) return null;
    if (self.state != .open_and_joining and self.state != .closed_and_joining) return null;
    self.state = .joined;
    const waiters = self.waiters;
    self.waiters = null;
    return waiters;
}
fn notify(head: ?*Waiter) void {
    var next = head;
    while (next) |waiter| {
        next = waiter.next;
        waiter.notify(waiter);
    }
}
// Internal hooks for CountingScope, not association acquisition.
pub fn beginDispatch(self: *Self) void {
    self.mutex.lock();
    self.dispatches += 1;
    self.mutex.unlock();
}
pub fn endDispatch(self: *Self) void {
    self.mutex.lock();
    std.debug.assert(self.dispatches != 0);
    self.dispatches -= 1;
    const waiters = self.detachReadyLocked();
    self.mutex.unlock();
    notify(waiters);
}

const Waiter = struct {
    next: ?*Waiter = null,
    notify: *const fn (*Waiter) void,
};
pub const Join = ex.Sender(JoinImpl);
pub fn join(self: *Self) Join {
    return ex.asSender(JoinImpl{ .scope = self });
}
const JoinImpl = struct {
    scope: *Self,
    pub const Values = Empty;
    // Scheduling completion may report scheduler error/stopped, never task errors.
    pub const can_error = true;
    pub fn Operation(comptime R: type) type {
        return struct {
            scope: *Self,
            receiver: ex.TypedReceiver(Empty, R),
            waiter: Waiter = .{ .notify = notifyReady },
            transfer: ex.meta.OperationOf(ex.Schedule(ex.StartScheduler), ex.TypedReceiver(Empty, R)) = undefined,
            scheduler_error: ?anyerror = null,
            output: Empty = .{},
            pub fn start(self: *@This()) void {
                const scope = self.scope;
                scope.mutex.lock();
                if (scope.count == 0 and scope.dispatches == 0) {
                    scope.state = .joined;
                    scope.mutex.unlock();
                    const receiver = self.receiver;
                    if (self.scheduler_error) |err| receiver.setError(err) else receiver.setValue(&self.output);
                } else {
                    scope.state = switch (scope.state) {
                        .unused, .open, .open_and_joining => .open_and_joining,
                        .unused_and_closed, .closed, .closed_and_joining => .closed_and_joining,
                        .joined => .closed_and_joining, // Internal dispatch guard only.
                    };
                    self.waiter.next = scope.waiters;
                    scope.waiters = &self.waiter;
                    scope.mutex.unlock();
                }
            }
            fn notifyReady(waiter: *Waiter) void {
                const self: *@This() = @fieldParentPtr("waiter", waiter);
                self.scheduleCompletion();
            }
            fn scheduleCompletion(self: *@This()) void {
                if (self.scheduler_error) |err| self.receiver.setError(err) else self.transfer.start();
            }
        };
    }
    pub fn connectInto(self: @This(), out: anytype, receiver: anytype) void {
        out.* = .{ .scope = self.scope, .receiver = .init(receiver) };
        if (out.receiver.getEnv().getStartScheduler()) |scheduler| {
            ex.schedule(scheduler).connectInto(&out.transfer, out.receiver);
        } else |err| {
            // A runtime Env cannot reject connect at compile time. Still
            // drain associations before reporting an invalid environment.
            out.scheduler_error = err;
        }
    }
};
