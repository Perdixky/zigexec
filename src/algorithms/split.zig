const std = @import("std");
const c = @import("../execution/protocol.zig");
const sync = @import("../detail/sync.zig");
const fluent = @import("../execution/sender.zig");

/// Explicitly owned shared computation. Use clone() for an additional owner,
/// deinit() exactly once per owner, and sender() for a borrowed sender view.
/// Any subscriber's stop request requests stop of the shared upstream operation.
pub fn Shared(comptime S: type) type {
    return struct {
        state: *State,
        const Self = @This();
        pub const Values = S.Values;
        const Result = c.Completion(Values);

        const State = struct {
            allocator: std.mem.Allocator,
            references: std.atomic.Value(usize) = .init(1),
            mutex: sync.Mutex = .{},
            upstream: S,
            operation: @import("../execution/connect.zig").Connection(S) = undefined,
            stop: c.StopSource = .{},
            started: bool = false,
            result: ?Result = null,
            waiters: ?*View.Operation = null,

            fn retain(self: *State) void {
                _ = self.references.fetchAdd(1, .monotonic);
            }
            fn release(self: *State) void {
                if (self.references.fetchSub(1, .acq_rel) != 1) return;
                self.stop.deinit();
                self.allocator.destroy(self);
            }
            pub fn getEnv(self: *State) c.Env {
                // Shared work can outlive every individual subscriber. Its owner
                // provides the allocator rather than borrowing a subscriber arena.
                return .{ .allocator = self.allocator, .stop_token = self.stop.token() };
            }
            fn complete(self: *State, result: Result) void {
                self.mutex.lock();
                std.debug.assert(self.result == null);
                self.result = result;
                var waiters = self.waiters;
                self.waiters = null;
                self.mutex.unlock();
                while (waiters) |waiter| {
                    waiters = waiter.next;
                    waiter.finish(&self.result.?);
                }
                // The upstream reference keeps State alive throughout notification,
                // including reentrant subscriptions and owner destruction.
            }
            pub fn setFinished(self: *State) void {
                self.release();
            }
            pub fn setValue(self: *State, values: *const Values) void {
                self.complete(.{ .value = values.* });
            }
            pub fn setError(self: *State, err: anyerror) void {
                self.complete(.{ .err = err });
            }
            pub fn setStopped(self: *State) void {
                self.complete(.stopped);
            }
        };

        pub const View = struct {
            state: *State,
            pub const Values = S.Values;
            pub const Operation = struct {
                state: *State,
                receiver: c.Receiver(S.Values),
                next: ?*@This() = null,
                result: Result = undefined,
                stop_callback: c.StopCallback = .{},
                started: bool = false,
                const Op = @This();
                pub fn start(self: *Op) void {
                    std.debug.assert(!self.started);
                    self.started = true;
                    const state = self.state;
                    c.Scope.acquire(self.receiver.env.scope);
                    state.retain(); // This subscription owns State until finish.
                    self.stop_callback.init(self.receiver.env.stop_token, self, cancel);
                    state.mutex.lock();
                    if (state.result) |*result| {
                        state.mutex.unlock();
                        self.finish(result);
                        return;
                    }
                    const first = !state.started;
                    if (first) {
                        state.started = true;
                        state.retain(); // Independent lifetime for the upstream.
                    }
                    self.next = state.waiters;
                    state.waiters = self;
                    state.mutex.unlock();
                    if (first) {
                        state.operation = c.connect(state.upstream, state);
                        state.operation.start();
                    }
                }
                fn cancel(ctx: *anyopaque) void {
                    const self: *Op = @ptrCast(@alignCast(ctx));
                    const scope = self.receiver.env.scope;
                    c.Scope.acquire(scope);
                    defer c.Scope.release(scope);
                    const state = self.state;
                    state.retain();
                    _ = state.stop.requestStop();
                    state.release();
                }
                fn finish(self: *Op, result: *const Result) void {
                    const receiver = self.receiver;
                    const scope = receiver.env.scope;
                    const state = self.state;
                    self.result = result.*;
                    self.stop_callback.deinit();
                    state.release();
                    receiver.complete(&self.result);
                    c.Scope.release(scope);
                }
            };
            pub fn connect(self: View, receiver: c.Receiver(S.Values)) Operation {
                return .{ .state = self.state, .receiver = receiver };
            }
        };

        pub fn clone(self: Self) Self {
            self.state.retain();
            return self;
        }
        pub fn deinit(self: *Self) void {
            const state = self.state;
            self.* = undefined;
            state.release();
        }
        /// Keep an owner alive until this view's operation is started. Started
        /// subscriptions and upstream work retain their own references.
        pub fn sender(self: Self) fluent.Sender(View) {
            return fluent.asSender(View{ .state = self.state });
        }
        pub fn requestStop(self: Self) bool {
            const state = self.state;
            state.retain();
            defer state.release();
            return state.stop.requestStop();
        }
    };
}

pub fn split(allocator: std.mem.Allocator, sender: anytype) !Shared(@TypeOf(sender)) {
    const T = Shared(@TypeOf(sender));
    const state = try allocator.create(T.State);
    state.* = .{ .allocator = allocator, .upstream = sender };
    return .{ .state = state };
}
