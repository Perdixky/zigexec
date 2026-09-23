const std = @import("std");
const StartGuard = @import("../detail/start_guard.zig").StartGuard;
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

        // The heterogeneous subscription queue erases only queue notification,
        // not the receiver stored in each concrete subscription operation.
        const Waiter = struct {
            next: ?*Waiter = null,
            notify: *const fn (*Waiter, *const Result) void,
        };
        const State = struct {
            allocator: std.mem.Allocator,
            references: std.atomic.Value(usize) = .init(1),
            mutex: sync.Mutex = .{},
            operation: @import("../execution/connect.zig").Connection(S, *State) = undefined,
            stop: c.StopSource = .{},
            started: bool = false,
            result: ?Result = null,
            waiters: ?*Waiter = null,

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
                    waiter.notify(waiter, &self.result.?);
                }
                // The upstream reference protects this notification loop, including
                // reentrant subscriptions and owner destruction. Release last.
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
            pub const can_error = @import("../detail/completion_traits.zig").canError(S);
            pub fn Operation(comptime R: type) type {
                return struct {
                    state: *State,
                    receiver: c.TypedReceiver(S.Values, R),
                    waiter: Waiter = .{ .notify = notify },
                    result: Result = undefined,
                    stop_callback: c.StopCallbackFor(R) = .{},
                    started: StartGuard = .{},
                    const Op = @This();
                    pub fn start(self: *Op) void {
                        self.started.begin();
                        const state = self.state;
                        state.retain(); // This subscription owns State until finish.
                        self.stop_callback.init(self.receiver.getEnv().stop_token, self, cancel);
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
                        self.waiter.next = state.waiters;
                        state.waiters = &self.waiter;
                        state.mutex.unlock();
                        if (first) {
                            state.operation.start();
                        }
                    }
                    fn cancel(ctx: *anyopaque) void {
                        const self: *Op = @ptrCast(@alignCast(ctx));
                        const state = self.state;
                        state.retain();
                        _ = state.stop.requestStop();
                        state.release();
                    }
                    fn notify(waiter: *Waiter, result: *const Result) void {
                        const self: *Op = @fieldParentPtr("waiter", waiter);
                        self.finish(result);
                    }
                    fn finish(self: *Op, result: *const Result) void {
                        const receiver = self.receiver;
                        const state = self.state;
                        self.result = result.*;
                        self.stop_callback.deinit();
                        state.release();
                        receiver.complete(&self.result);
                    }
                };
            }
            pub fn connectInto(self: View, out: anytype, receiver: anytype) void {
                out.* = .{ .state = self.state, .receiver = .init(receiver) };
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
    state.* = .{ .allocator = allocator };
    c.connectInto(&state.operation, sender, state);
    return .{ .state = state };
}
