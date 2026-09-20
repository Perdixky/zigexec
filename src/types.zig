//! Public, exact concrete sender types. Constructors use type arguments only;
//! their instances retain static operation layouts without allocation or erasure.
const fluent = @import("execution/sender.zig");
const c = @import("detail/callable.zig");
const meta = @import("meta.zig");
const Transform = @import("algorithms/detail/transform.zig").Transform;
const Let = @import("algorithms/detail/let.zig").Let;

pub const Sender = fluent.Sender;
pub fn Immediate(comptime Values: type) type {
    return Sender(@import("senders/immediate.zig").Immediate(Values));
}
pub fn Just(comptime value_types: anytype) type {
    return Sender(@import("senders/immediate.zig").ImmediateKind(meta.Values(value_types), .value));
}
pub fn JustError(comptime value_types: anytype) type {
    return Sender(@import("senders/immediate.zig").ImmediateKind(meta.Values(value_types), .err));
}
pub fn JustStopped(comptime value_types: anytype) type {
    return Sender(@import("senders/immediate.zig").ImmediateKind(meta.Values(value_types), .stopped));
}
pub const ReadEnv = Sender(@import("senders/read_env.zig").ReadEnv);
pub const ReadAllocator = Sender(@import("senders/read_allocator.zig").ReadAllocator);

pub fn Then(comptime S: type, comptime F: type) type {
    return Sender(Transform(S, c.Stored(F), .value));
}
pub fn UponError(comptime S: type, comptime F: type) type {
    return Sender(Transform(S, c.Stored(F), .err));
}
pub fn UponStopped(comptime S: type, comptime F: type) type {
    return Sender(Transform(S, c.Stored(F), .stopped));
}
/// Target is a factory callback type, a sender type, or a deferred subchain type.
pub fn LetValue(comptime S: type, comptime Target: type) type {
    return Sender(@import("algorithms/let_value.zig").LetValue(S, Target));
}
pub fn LetError(comptime S: type, comptime F: type) type {
    return Sender(Let(S, c.Stored(F), .err));
}
pub fn LetStopped(comptime S: type, comptime F: type) type {
    return Sender(Let(S, c.Stored(F), .stopped));
}
pub fn WhenAll(comptime sender_types: anytype) type {
    return Sender(@import("algorithms/when_all.zig").WhenAll(meta.Values(sender_types)));
}
pub fn Bulk(comptime S: type, comptime F: type) type {
    return Sender(@import("algorithms/bulk.zig").Bulk(S, c.Stored(F)));
}
pub fn WithStopToken(comptime S: type) type {
    return Sender(@import("algorithms/with_stop_token.zig").WithStopToken(S));
}
pub fn Schedule(comptime Scheduler: type) type {
    return Sender(@TypeOf(@as(Scheduler, undefined).schedule()));
}
pub fn StartsOn(comptime Scheduler: type, comptime S: type) type {
    return Sender(@import("algorithms/starts_on.zig").StartsOn(Scheduler, S));
}
pub fn ContinuesOn(comptime S: type, comptime Scheduler: type) type {
    return Sender(@import("algorithms/continues_on.zig").ContinuesOn(S, Scheduler));
}

pub fn Repeat(comptime S: type) type {
    return Sender(@import("algorithms/repeat.zig").Repeat(S, false));
}
pub fn RepeatUntil(comptime S: type) type {
    return Sender(@import("algorithms/repeat.zig").Repeat(S, true));
}

/// Input container type preserves tuple indices or named branch tags.
pub fn WhenAny(comptime Senders: type) type {
    return Sender(@import("algorithms/when_any.zig").WhenAny(Senders));
}

/// Compatibility aliases; prefer Repeat / RepeatUntil.
pub const RepeatEffect = Repeat;
pub const RepeatEffectUntil = RepeatUntil;
