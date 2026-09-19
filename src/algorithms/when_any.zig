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
fn Operations(comptime Senders: type) type {
    const fields = @typeInfo(Senders).@"struct".field_types;
    var types: [fields.len]type = undefined;
    for (fields, 0..) |S, i| types[i] = ex.Connection(S);
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
        pub const Operation = struct {
            senders: Senders,
            receiver: ex.Receiver(Values),
            children: Operations(Senders) = undefined,
            stop: ex.StopSource = .{},
            parent_stop: ex.StopCallback = .{},
            remaining: std.atomic.Value(usize) = .init(count + 1),
            winner: std.atomic.Value(usize) = .init(count),
            result: ex.Completion(Values) = undefined,
            started: bool = false,
            const Op = @This();
            pub fn start(self: *Op) void {
                std.debug.assert(!self.started);
                self.started = true;
                ex.Scope.acquire(self.receiver.env.scope);
                self.parent_stop.init(self.receiver.env.stop_token, self, cancel);
                inline for (fields.field_names, fields.field_types, 0..) |name, S, i| {
                    const Child = struct {
                        fn value(ctx: *anyopaque, values: *const S.Values) void {
                            const op: *Op = @ptrCast(@alignCast(ctx));
                            if (op.claim(i)) {
                                op.result = .{ .value = .{@unionInit(Result, name, values.*)} };
                                _ = op.stop.requestStop();
                            }
                        }
                        fn err(ctx: *anyopaque, e: anyerror) void {
                            const op: *Op = @ptrCast(@alignCast(ctx));
                            if (op.claim(i)) {
                                op.result = .{ .err = e };
                                _ = op.stop.requestStop();
                            }
                        }
                        fn stopped(ctx: *anyopaque) void {
                            const op: *Op = @ptrCast(@alignCast(ctx));
                            if (op.claim(i)) {
                                op.result = .stopped;
                                _ = op.stop.requestStop();
                            }
                        }
                        fn finished(ctx: *anyopaque) void {
                            const op: *Op = @ptrCast(@alignCast(ctx));
                            op.finishOne();
                        }
                    };
                    self.children[i] = .{ .sender = @field(self.senders, name), .receiver = .{
                        .context = self,
                        .value_fn = Child.value,
                        .error_fn = Child.err,
                        .stopped_fn = Child.stopped,
                        .finished_fn = Child.finished,
                        .env = self.receiver.env.withStopToken(self.stop.token()),
                    } };
                    // Branch execution retirement is not the end of downstream
                    // borrowing. Association records live in embedded storage;
                    // release them only when the containing graph retires.
                    self.children[i].scope.retirement_owner = self.receiver.env.scope;
                }
                inline for (&self.children) |*child| child.start();
                self.finishOne();
            }
            fn claim(self: *Op, index: usize) bool {
                return self.winner.cmpxchgStrong(count, index, .acq_rel, .acquire) == null;
            }
            fn cancel(ctx: *anyopaque) void {
                const self: *Op = @ptrCast(@alignCast(ctx));
                const lifetime = self.receiver.env.scope;
                ex.Scope.acquire(lifetime);
                defer ex.Scope.release(lifetime);
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
                ex.Scope.release(receiver.env.scope);
            }
        };
        pub fn connect(self: @This(), receiver: ex.Receiver(Values)) Operation {
            return .{ .senders = self.senders, .receiver = receiver };
        }
    };
}
pub fn whenAny(senders: anytype) WhenAny(@TypeOf(senders)) {
    return .{ .senders = senders };
}
