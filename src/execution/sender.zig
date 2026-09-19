//! Uniform fluent facade. Free functions and methods use the same algorithms.
const ex = @import("../root.zig");

pub fn Sender(comptime Impl: type) type {
    if (isFacade(Impl)) return Impl;
    return struct {
        pub const __zigexec_facade = true;
        pub const Implementation = Impl;
        inner: Impl,
        pub const Values = Impl.Values;
        pub const can_error = @import("../detail/completion_traits.zig").canError(Impl);
        pub const Operation = Impl.Operation;
        const Self = @This();

        // Type-level counterparts mirror fluent runtime composition.
        pub fn Then(comptime Callback: type) type {
            return ex.Then(Self, Callback);
        }
        pub fn UponError(comptime Callback: type) type {
            return ex.UponError(Self, Callback);
        }
        pub fn UponStopped(comptime Callback: type) type {
            return ex.UponStopped(Self, Callback);
        }
        pub fn LetValue(comptime Target: type) type {
            return ex.LetValue(Self, Target);
        }
        pub fn LetError(comptime Callback: type) type {
            return ex.LetError(Self, Callback);
        }
        pub fn LetStopped(comptime Callback: type) type {
            return ex.LetStopped(Self, Callback);
        }
        pub fn Bulk(comptime Callback: type) type {
            return ex.Bulk(Self, Callback);
        }
        pub fn RepeatEffect() type {
            return ex.RepeatEffect(Self);
        }
        pub fn RepeatEffectUntil() type {
            return ex.RepeatEffectUntil(Self);
        }
        pub fn StartsOn(comptime Scheduler: type) type {
            return ex.StartsOn(Scheduler, Self);
        }
        pub fn ContinuesOn(comptime Scheduler: type) type {
            return ex.ContinuesOn(Self, Scheduler);
        }
        pub fn WithStopToken() type {
            return ex.WithStopToken(Self);
        }

        pub fn connect(self: Self, receiver: ex.Receiver(Values)) Operation {
            return self.inner.connect(receiver);
        }
        pub fn then(self: Self, comptime Callback: type, args: anytype) ex.Then(Self, Callback) {
            return ex.then(self, Callback, args);
        }
        pub fn uponError(self: Self, comptime Callback: type, args: anytype) ex.UponError(Self, Callback) {
            return ex.uponError(self, Callback, args);
        }
        pub fn uponStopped(self: Self, comptime Callback: type, args: anytype) ex.UponStopped(Self, Callback) {
            return ex.uponStopped(self, Callback, args);
        }
        pub fn letValue(self: Self, target: anytype, args: anytype) ex.LetValue(Self, if (@TypeOf(target) == type) target else @TypeOf(target)) {
            return ex.letValue(self, target, args);
        }
        pub fn letError(self: Self, comptime Callback: type, args: anytype) ex.LetError(Self, Callback) {
            return ex.letError(self, Callback, args);
        }
        pub fn letStopped(self: Self, comptime Callback: type, args: anytype) ex.LetStopped(Self, Callback) {
            return ex.letStopped(self, Callback, args);
        }
        pub fn bulk(self: Self, count: usize, comptime Callback: type, args: anytype) ex.Bulk(Self, Callback) {
            return ex.bulk(self, count, Callback, args);
        }
        pub fn repeatEffect(self: Self) ex.RepeatEffect(Self) {
            return ex.repeatEffect(self);
        }
        pub fn repeatEffectUntil(self: Self) ex.RepeatEffectUntil(Self) {
            return ex.repeatEffectUntil(self);
        }
        pub fn startsOn(self: Self, scheduler: anytype) ex.StartsOn(@TypeOf(scheduler), Self) {
            return ex.startsOn(scheduler, self);
        }
        pub fn continuesOn(self: Self, scheduler: anytype) ex.ContinuesOn(Self, @TypeOf(scheduler)) {
            return ex.continuesOn(self, scheduler);
        }
        pub fn withStopToken(self: Self, token: ex.StopToken) ex.WithStopToken(Self) {
            return ex.withStopToken(self, token);
        }
        pub fn split(self: Self, allocator: @import("std").mem.Allocator) !ex.Shared(Self) {
            return ex.split(allocator, self);
        }
        pub fn associate(self: Self, token: anytype) ex.Associated(Self, @TypeOf(token)) {
            return ex.associate(self, token);
        }
        pub fn syncWait(self: Self, env: ex.Env) anyerror!?Values {
            return ex.syncWait(self, env);
        }
    };
}

/// Give any custom sender the fluent API without changing its protocol.
pub fn asSender(implementation: anytype) Sender(@TypeOf(implementation)) {
    if (comptime isFacade(@TypeOf(implementation))) return implementation;
    return .{ .inner = implementation };
}

fn isFacade(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "__zigexec_facade");
}
