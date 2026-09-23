const std = @import("std");
const StartGuard = @import("../detail/start_guard.zig").StartGuard;
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

fn ChildTuple(comptime Senders: type, comptime Parent: type, comptime results: bool) type {
    const fields = @typeInfo(Senders).@"struct".field_types;
    var types: [fields.len]type = undefined;
    for (fields, 0..) |f, i| types[i] = if (results) c.CompletionRef(f.Values) else c.OperationOf(f, Parent.Child(i));
    return @Tuple(&types);
}

pub fn WhenAll(comptime Senders: type) type {
    const V = AllValues(Senders);
    const count = @typeInfo(Senders).@"struct".field_types.len;
    // Like stdexec's zero/single-input overloads: no fan-in, no private stop
    // source, no result copy, and no arrival atomics are needed here.
    if (count <= 1) return struct {
        senders: Senders,
        const Base = if (count == 1) @typeInfo(Senders).@"struct".field_types[0] else @import("../senders/immediate.zig").ImmediateKind(V, .value);
        pub const Values = V;
        pub const can_error = @import("../detail/completion_traits.zig").canError(Base);
        pub fn Operation(comptime R: type) type {
            return c.OperationOf(Base, R);
        }
        pub fn connectInto(self: @This(), out: anytype, receiver: anytype) void {
            const base: Base = if (count == 1) self.senders[0] else .{ .result = .{ .value = .{} } };
            c.connectChild(out, base, receiver);
        }
    };
    return struct {
        senders: Senders,
        pub const Values = V;
        pub const can_error = blk: {
            for (@typeInfo(Senders).@"struct".field_types) |S| {
                if (@import("../detail/completion_traits.zig").canError(S)) break :blk true;
            }
            break :blk false;
        };
        const Self = @This();
        pub fn Operation(comptime R: type) type {
            return struct {
                receiver: c.TypedReceiver(V, R),
                children: ChildTuple(Senders, Op, false) = undefined,
                output: V = undefined,
                results: ChildTuple(Senders, Op, true) = undefined,
                stop: c.StopSource = .{},
                parent_stop: c.StopCallbackFor(R) = .{},
                // The extra reference prevents inline completion from destroying us
                // while the loop is still starting other children.
                remaining: std.atomic.Value(usize) = .init(count + 1),
                first_error: std.atomic.Value(usize) = .init(count),
                started: StartGuard = .{},
                const Op = @This();
                pub fn cleanup(self: *Op, continuation: anytype) void {
                    var children: ChildPointers() = undefined;
                    inline for (&self.children, 0..) |*child, i| children[i] = child;
                    c.cleanupOperations(children, continuation);
                }
                fn ChildPointers() type {
                    const Children = @FieldType(Op, "children");
                    const child_types = @typeInfo(Children).@"struct".field_types;
                    var pointers: [child_types.len]type = undefined;
                    for (child_types, 0..) |ChildOp, i| pointers[i] = *ChildOp;
                    return @Tuple(&pointers);
                }
                pub fn start(self: *Op) void {
                    self.started.begin();
                    self.parent_stop.init(self.receiver.getEnv().stop_token, self, requestStop);
                    inline for (&self.children) |*child| child.start();
                    self.finishOne();
                }
                fn Child(comptime i: usize) type {
                    const S = @typeInfo(Senders).@"struct".field_types[i];
                    return struct {
                        op: *Op,
                        pub fn getEnv(self: @This()) c.Env {
                            return self.op.receiver.getEnv().withStopToken(self.op.stop.token());
                        }
                        pub fn setValue(self: @This(), values: *const S.Values) void {
                            self.op.results[i] = .{ .value = values };
                            self.op.finishOne();
                        }
                        pub fn setError(self: @This(), e: anyerror) void {
                            self.op.results[i] = .{ .err = e };
                            _ = self.op.first_error.cmpxchgStrong(count, i, .monotonic, .monotonic);
                            _ = self.op.stop.requestStop();
                            self.op.finishOne();
                        }
                        pub fn setStopped(self: @This()) void {
                            self.op.results[i] = .stopped;
                            _ = self.op.stop.requestStop();
                            self.op.finishOne();
                        }
                    };
                }
                fn requestStop(ctx: *anyopaque) void {
                    const self: *Op = @ptrCast(@alignCast(ctx));
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
        }
        pub fn connectInto(self: Self, out: anytype, receiver: anytype) void {
            out.* = .{ .receiver = .init(receiver) };
            inline for (self.senders, 0..) |sender, i| c.connectChild(&out.children[i], sender, Operation(@TypeOf(receiver)).Child(i){ .op = out });
        }
    };
}

pub fn whenAll(senders: anytype) WhenAll(@TypeOf(senders)) {
    return .{ .senders = senders };
}
