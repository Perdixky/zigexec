//! First completion wins; cancel peers and retire every branch before forwarding.
const std = @import("std");
const ex = @import("../root.zig");
const retainUnlessDone = @import("../detail/lifetime.zig").retainUnlessDone;

fn validate(comptime Senders: type) void {
    if (@typeInfo(Senders) != .@"struct") @compileError("zigexec.whenAny: expected a tuple or named struct of senders");
    const fields = @typeInfo(Senders).@"struct";
    if (fields.field_types.len == 0) @compileError("zigexec.whenAny: requires at least one sender");
    for (fields.field_types) |S| @import("../detail/diagnostics.zig").requireSender(S, S, "whenAny");
}
fn ResultUnion(comptime Senders: type) type {
    const fields = @typeInfo(Senders).@"struct";
    const n = fields.field_types.len;
    var types: [n]type = undefined;
    const TagInt = std.math.IntFittingRange(0, n - 1);
    var tags: [n]TagInt = undefined;
    for (fields.field_types, 0..) |S, i| {
        types[i] = S.Values;
        tags[i] = @intCast(i);
    }
    const Tag = @Enum(TagInt, .exhaustive, fields.field_names, &tags);
    return @Union(.auto, Tag, fields.field_names, &types, &@splat(.{}));
}
fn Operations(comptime Senders: type, comptime Parent: type) type {
    const fields = @typeInfo(Senders).@"struct".field_types;
    var types: [fields.len]type = undefined;
    for (fields, 0..) |S, i| types[i] = ex.meta.OperationOf(S, Parent.Child(i));
    return @Tuple(&types);
}

pub fn WhenAny(comptime Senders: type) type {
    validate(Senders);
    const fields = @typeInfo(Senders).@"struct";
    const count = fields.field_types.len;
    const Result = ResultUnion(Senders);
    return struct {
        senders: Senders,
        pub const Values = @Tuple(&.{Result});
        pub const can_error = blk: {
            for (fields.field_types) |S| if (@import("../detail/completion_traits.zig").canError(S)) {
                break :blk true;
            };
            break :blk false;
        };
        pub fn Operation(comptime R: type) type {
            return struct {
                receiver: ex.TypedReceiver(Values, R),
                children: Operations(Senders, Op) = undefined,
                stop: ex.StopSource = .{},
                parent_stop: ex.StopCallbackFor(R) = .{},
                remaining: std.atomic.Value(usize) = .init(count + 1),
                winner: std.atomic.Value(usize) = .init(count),
                result: ex.Completion(Values) = undefined,
                started: bool = false,
                const Op = @This();
                pub fn start(self: *Op) void {
                    std.debug.assert(!self.started);
                    self.started = true;
                    self.parent_stop.init(self.receiver.getEnv().stop_token, self, cancel);
                    inline for (&self.children) |*child| child.start();
                    self.finishOne();
                }
                fn Child(comptime i: usize) type {
                    const S = fields.field_types[i];
                    const name = fields.field_names[i];
                    return struct {
                        op: *Op,
                        pub fn getEnv(self: @This()) ex.Env {
                            return self.op.receiver.getEnv().withStopToken(self.op.stop.token());
                        }
                        pub fn setValue(self: @This(), values: *const S.Values) void {
                            if (self.op.claim(i)) {
                                self.op.result = .{ .value = .{@unionInit(Result, name, values.*)} };
                                _ = self.op.stop.requestStop();
                            }
                            self.op.finishOne();
                        }
                        pub fn setError(self: @This(), e: anyerror) void {
                            if (self.op.claim(i)) {
                                self.op.result = .{ .err = e };
                                _ = self.op.stop.requestStop();
                            }
                            self.op.finishOne();
                        }
                        pub fn setStopped(self: @This()) void {
                            if (self.op.claim(i)) {
                                self.op.result = .stopped;
                                _ = self.op.stop.requestStop();
                            }
                            self.op.finishOne();
                        }
                    };
                }
                fn claim(self: *Op, index: usize) bool {
                    return self.winner.cmpxchgStrong(count, index, .acq_rel, .acquire) == null;
                }
                fn cancel(ctx: *anyopaque) void {
                    const self: *Op = @ptrCast(@alignCast(ctx));
                    if (!retainUnlessDone(&self.remaining)) return;
                    _ = self.stop.requestStop();
                    self.finishOne();
                }
                fn finishOne(self: *Op) void {
                    if (self.remaining.fetchSub(1, .acq_rel) != 1) return;
                    self.parent_stop.deinit();
                    self.stop.deinit();
                    const receiver = self.receiver;
                    receiver.complete(&self.result);
                }
            };
        }
        pub fn connectInto(self: @This(), out: anytype, receiver: anytype) void {
            out.* = .{ .receiver = .init(receiver) };
            inline for (fields.field_names, 0..) |name, i| {
                @import("../execution/protocol.zig").connectChild(&out.children[i], @field(self.senders, name), Operation(@TypeOf(receiver)).Child(i){ .op = out });
                // Branch completion does not end downstream borrowing of associations.
            }
        }
    };
}
pub fn whenAny(senders: anytype) WhenAny(@TypeOf(senders)) {
    return .{ .senders = senders };
}
