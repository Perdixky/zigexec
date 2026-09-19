//! Zig-native sender/receiver execution, inspired by P2300 and NVIDIA stdexec.
const core = @import("execution/protocol.zig");
const wait = @import("consumers/sync_wait.zig");
const fluent = @import("execution/sender.zig");
pub const meta = @import("meta.zig");
const types = @import("types.zig");
pub const Values = meta.Values;
pub const Sender = types.Sender;
pub const Immediate = types.Immediate;
pub const Just = types.Just;
pub const JustError = types.JustError;
pub const JustStopped = types.JustStopped;
pub const ReadEnv = types.ReadEnv;
pub const ReadAllocator = types.ReadAllocator;
pub const Then = types.Then;
pub const UponError = types.UponError;
pub const UponStopped = types.UponStopped;
pub const LetValue = types.LetValue;
pub const upstream = @import("expressions/upstream.zig").upstream;
pub const Fn = @import("callbacks/function.zig").Fn;
const initCallback = @import("callbacks/init.zig").init;
pub const LetError = types.LetError;
pub const LetStopped = types.LetStopped;
pub const WhenAll = types.WhenAll;
pub const Bulk = types.Bulk;
pub const RepeatEffect = types.RepeatEffect;
pub const RepeatEffectUntil = types.RepeatEffectUntil;
pub const WithStopToken = types.WithStopToken;
pub const Schedule = types.Schedule;
pub const StartsOn = types.StartsOn;
pub const ContinuesOn = types.ContinuesOn;
pub const Bind = @import("callbacks/bind.zig").Bind;
pub const bind = @import("callbacks/bind.zig").bind;
pub const asSender = fluent.asSender;

pub const Env = core.Env;
pub const StopSource = core.StopSource;
pub const StopToken = core.StopToken;
pub const StopCallback = core.StopCallback;
pub const Completion = core.Completion;
pub const Receiver = core.Receiver;
pub const Connection = @import("execution/connect.zig").Connection;
pub const Scope = core.Scope;
pub const connect = core.connect;
pub const start = core.start;
pub fn just(values: anytype) Immediate(@import("detail/tuple.zig").ValueTuple(@TypeOf(values))) {
    return asSender(@import("senders/just.zig").just(values));
}
pub fn justError(comptime ValueTuple: type, err: anyerror) Immediate(ValueTuple) {
    return asSender(@import("senders/just_error.zig").justError(ValueTuple, err));
}
pub fn justStopped(comptime ValueTuple: type) Immediate(ValueTuple) {
    return asSender(@import("senders/just_stopped.zig").justStopped(ValueTuple));
}
pub fn readAllocator() ReadAllocator {
    return asSender(@import("senders/read_allocator.zig").ReadAllocator{});
}
pub fn readEnv() ReadEnv {
    return asSender(@import("senders/read_env.zig").readEnv());
}
pub fn withStopToken(sender: anytype, token: StopToken) WithStopToken(@TypeOf(sender)) {
    return asSender(@import("algorithms/with_stop_token.zig").withStopToken(sender, token));
}
pub fn then(sender: anytype, comptime Callback: type, args: anytype) Then(@TypeOf(sender), Callback) {
    return asSender(@import("algorithms/then.zig").then(sender, initCallback(Callback, args)));
}
pub fn uponError(sender: anytype, comptime Callback: type, args: anytype) UponError(@TypeOf(sender), Callback) {
    return asSender(@import("algorithms/upon_error.zig").uponError(sender, initCallback(Callback, args)));
}
pub fn uponStopped(sender: anytype, comptime Callback: type, args: anytype) UponStopped(@TypeOf(sender), Callback) {
    return asSender(@import("algorithms/upon_stopped.zig").uponStopped(sender, initCallback(Callback, args)));
}
/// After success, call a factory type initialized with args, bind an upstream()
/// subchain, or start an existing sender. Subchains and senders require .{} args;
/// an existing sender ignores upstream values. Errors/stops bypass the target.
pub fn letValue(sender: anytype, target: anytype, args: anytype) LetValue(@TypeOf(sender), if (@TypeOf(target) == type) target else @TypeOf(target)) {
    return asSender(@import("algorithms/let_value.zig").letValue(sender, target, args));
}
pub fn letError(sender: anytype, comptime Callback: type, args: anytype) LetError(@TypeOf(sender), Callback) {
    return asSender(@import("algorithms/let_error.zig").letError(sender, initCallback(Callback, args)));
}
pub fn letStopped(sender: anytype, comptime Callback: type, args: anytype) LetStopped(@TypeOf(sender), Callback) {
    return asSender(@import("algorithms/let_stopped.zig").letStopped(sender, initCallback(Callback, args)));
}
pub fn whenAll(senders_tuple: anytype) WhenAll(@typeInfo(@TypeOf(senders_tuple)).@"struct".field_types) {
    const Tuple = Values(@typeInfo(@TypeOf(senders_tuple)).@"struct".field_types);
    return asSender(@import("algorithms/when_all.zig").whenAll(@as(Tuple, senders_tuple)));
}
pub fn bulk(sender: anytype, count: usize, comptime Callback: type, args: anytype) Bulk(@TypeOf(sender), Callback) {
    return asSender(@import("algorithms/bulk.zig").bulk(sender, count, initCallback(Callback, args)));
}
pub fn repeatEffect(sender: anytype) RepeatEffect(@TypeOf(sender)) {
    return .{ .inner = .{ .sender = sender } };
}
pub fn repeatEffectUntil(sender: anytype) RepeatEffectUntil(@TypeOf(sender)) {
    return .{ .inner = .{ .sender = sender } };
}
pub fn schedule(scheduler: anytype) Schedule(@TypeOf(scheduler)) {
    return asSender(@import("execution/schedule.zig").schedule(scheduler));
}
pub fn startsOn(scheduler: anytype, sender: anytype) StartsOn(@TypeOf(scheduler), @TypeOf(sender)) {
    return asSender(@import("algorithms/starts_on.zig").startsOn(scheduler, sender));
}
pub fn continuesOn(sender: anytype, scheduler: anytype) ContinuesOn(@TypeOf(sender), @TypeOf(scheduler)) {
    return asSender(@import("algorithms/continues_on.zig").continuesOn(sender, scheduler));
}
pub const InlineScheduler = @import("schedulers/inline.zig").InlineScheduler;
pub const ThreadPool = @import("schedulers/thread_pool.zig").ThreadPool;
pub const RunLoop = @import("schedulers/run_loop.zig").RunLoop;
pub const syncWait = wait.syncWait;

pub const Shared = @import("algorithms/split.zig").Shared;
pub const split = @import("algorithms/split.zig").split;

pub const io = @import("io/root.zig");
pub const IoUring = @import("backends/io_uring/context.zig");
