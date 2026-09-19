const std = @import("std");
const retainUnlessDone = @import("../detail/lifetime.zig").retainUnlessDone;
const c = @import("../execution/protocol.zig");
fn AllValues(comptime Senders: type) type {
    var count: usize = 0;
    for (@typeInfo(Senders).@"struct".field_types) |f| count += @typeInfo(f.Values).@"struct".field_types.len;
    var types: [count]type = undefined;
    var i: usize = 0;
    for (@typeInfo(Senders).@"struct".field_types) |f| {
        for (@typeInfo(f.Values).@"struct".field_types) |v| {
            types[i] = v;
            i += 1;
        }
    }
    return @Tuple(&types);
}

fn ChildTuple(comptime Senders: type, comptime results: bool) type {
    const fields = @typeInfo(Senders).@"struct".field_types;
    var types: [fields.len]type = undefined;
    for (fields, 0..) |f, i| types[i] = if (results) c.CompletionRef(f.Values) else f.Operation;
    return @Tuple(&types);
}

pub fn WhenAll(comptime Senders: type) type {
    const V = AllValues(Senders);
    const count = @typeInfo(Senders).@"struct".field_types.len;
    return struct {
        senders: Senders,
        pub const Values = V;
        const Self = @This();
        pub const Operation = struct {
            senders: Senders,
            receiver: c.Receiver(V),
            children: ChildTuple(Senders, false) = undefined,
            output: V = undefined,
            results: ChildTuple(Senders, true) = undefined,
            stop: c.StopSource = .{},
            parent_stop: c.StopCallback = .{},
            // The extra reference prevents inline completion from destroying us
            // while the loop is still starting other children.
            remaining: std.atomic.Value(usize) = .init(count + 1),
            first_error: std.atomic.Value(usize) = .init(count),
            started: bool = false,
            const Op = @This();
            pub fn start(self: *Op) void {
                std.debug.assert(!self.started);
                self.started = true;
                self.parent_stop.init(self.receiver.env.stop_token, self, requestStop);
                inline for (self.senders, 0..) |sender, i| {
                    const Child = struct {
                        fn value(ctx: *anyopaque, values: *const @TypeOf(sender).Values) void {
                            const op: *Op = @ptrCast(@alignCast(ctx));
                            op.results[i] = .{ .value = values };
                            op.finishOne();
                        }
                        fn err(ctx: *anyopaque, e: anyerror) void {
                            const op: *Op = @ptrCast(@alignCast(ctx));
                            op.results[i] = .{ .err = e };
                            _ = op.first_error.cmpxchgStrong(count, i, .monotonic, .monotonic);
                            _ = op.stop.requestStop();
                            op.finishOne();
                        }
                        fn stopped(ctx: *anyopaque) void {
                            const op: *Op = @ptrCast(@alignCast(ctx));
                            op.results[i] = .stopped;
                            _ = op.stop.requestStop();
                            op.finishOne();
                        }
                    };
                    self.children[i] = sender.connect(.{
                        .context = self,
                        .value_fn = Child.value,
                        .error_fn = Child.err,
                        .stopped_fn = Child.stopped,
                        .env = self.receiver.env.withStopToken(self.stop.token()),
                    });
                }
                inline for (&self.children) |*child| child.start();
                self.finishOne();
            }
            fn requestStop(ctx: *anyopaque) void {
                const self: *Op = @ptrCast(@alignCast(ctx));
                const scope = self.receiver.env.scope;
                c.Scope.acquire(scope);
                defer c.Scope.release(scope);
                if (!retainUnlessDone(&self.remaining)) return;
                _ = self.stop.requestStop();
                self.finishOne();
            }
            fn finishOne(self: *Op) void {
                if (self.remaining.fetchSub(1, .acq_rel) != 1) return;
                self.parent_stop.deinit();
                self.stop.deinit();
                // Acquire all child writes before inspecting their independent slots.
                const first_error = self.first_error.load(.monotonic);
                inline for (self.results, 0..) |result, i| {
                    if (first_error == i) return self.receiver.setError(result.err);
                }
                inline for (self.results) |result| {
                    if (result == .stopped) return self.receiver.setStopped();
                }
                comptime var offset = 0;
                inline for (self.results) |result| {
                    inline for (result.value.*, 0..) |v, j| self.output[offset + j] = v;
                    offset += @typeInfo(@TypeOf(result.value.*)).@"struct".field_types.len;
                }
                self.receiver.setValue(&self.output);
            }
        };
        pub fn connect(self: Self, receiver: c.Receiver(V)) Operation {
            return .{ .senders = self.senders, .receiver = receiver };
        }
    };
}

pub fn whenAll(senders: anytype) WhenAll(@TypeOf(senders)) {
    return .{ .senders = senders };
}
