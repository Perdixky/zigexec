//! Deferred expression graph. Runtime captures are stored by value, while the
//! graph and callbacks are types. Binding supplies the nearest letValue input.
const ex = @import("../root.zig");
const init = @import("../callbacks/init.zig").init;
const continuation = @import("../algorithms/let_value.zig");
const Kind = enum { then, let_value, upon_error, upon_stopped, let_error, let_stopped, starts_on, continues_on, with_stop_token, bulk, repeat_effect, repeat_until };

pub fn Expression(comptime Impl: type) type {
    return struct {
        inner: Impl,
        pub const __zigexec_expression = true;
        const Self = @This();
        pub fn Bound(comptime Input: type) type {
            return Impl.Bound(Input);
        }
        pub fn bindInput(self: Self, input: anytype) Bound(@typeInfo(@TypeOf(input)).pointer.child) {
            return self.inner.bindInput(input);
        }
        pub fn then(self: Self, comptime Callback: type, args: anytype) Step(Self, Callback, .then) {
            return step(self, init(Callback, args), .then);
        }
        pub fn letValue(self: Self, target: anytype, args: anytype) Step(Self, if (@TypeOf(target) == type) target else @TypeOf(target), .let_value) {
            return step(self, continuation.capture(target, args), .let_value);
        }
        pub fn uponError(self: Self, comptime Callback: type, args: anytype) Step(Self, Callback, .upon_error) {
            return step(self, init(Callback, args), .upon_error);
        }
        pub fn uponStopped(self: Self, comptime Callback: type, args: anytype) Step(Self, Callback, .upon_stopped) {
            return step(self, init(Callback, args), .upon_stopped);
        }
        pub fn letError(self: Self, comptime Callback: type, args: anytype) Step(Self, Callback, .let_error) {
            return step(self, init(Callback, args), .let_error);
        }
        pub fn letStopped(self: Self, comptime Callback: type, args: anytype) Step(Self, Callback, .let_stopped) {
            return step(self, init(Callback, args), .let_stopped);
        }
        pub fn repeatEffect(self: Self) Step(Self, void, .repeat_effect) {
            return step(self, {}, .repeat_effect);
        }
        pub fn repeatEffectUntil(self: Self) Step(Self, void, .repeat_until) {
            return step(self, {}, .repeat_until);
        }
        pub fn startsOn(self: Self, scheduler: anytype) Step(Self, @TypeOf(scheduler), .starts_on) {
            return step(self, scheduler, .starts_on);
        }
        pub fn continuesOn(self: Self, scheduler: anytype) Step(Self, @TypeOf(scheduler), .continues_on) {
            return step(self, scheduler, .continues_on);
        }
        pub fn withStopToken(self: Self, token: ex.StopToken) Step(Self, ex.StopToken, .with_stop_token) {
            return step(self, token, .with_stop_token);
        }
        pub fn bulk(self: Self, count: usize, comptime Callback: type, args: anytype) Step(Self, BulkState(Callback), .bulk) {
            return step(self, BulkState(Callback){ .count = count, .callback = init(Callback, args) }, .bulk);
        }
    };
}

fn BulkState(comptime F: type) type {
    return struct {
        count: usize,
        callback: F,
        pub const Callback = F;
    };
}
fn step(parent: anytype, state: anytype, comptime kind: Kind) Step(@TypeOf(parent), @TypeOf(state), kind) {
    return .{ .inner = .{ .parent = parent, .state = state } };
}
fn Step(comptime Parent: type, comptime State: type, comptime kind: Kind) type {
    return Expression(struct {
        parent: Parent,
        state: State,
        pub fn Bound(comptime Input: type) type {
            const S = Parent.Bound(Input);
            return switch (kind) {
                .then => ex.Then(S, State),
                .let_value => ex.LetValue(S, State),
                .upon_error => ex.UponError(S, State),
                .upon_stopped => ex.UponStopped(S, State),
                .let_error => ex.LetError(S, State),
                .let_stopped => ex.LetStopped(S, State),
                .starts_on => ex.StartsOn(State, S),
                .continues_on => ex.ContinuesOn(S, State),
                .with_stop_token => ex.WithStopToken(S),
                .bulk => ex.Bulk(S, State.Callback),
                .repeat_effect => ex.RepeatEffect(S),
                .repeat_until => ex.RepeatEffectUntil(S),
            };
        }
        pub fn bindInput(self: @This(), input: anytype) Bound(@typeInfo(@TypeOf(input)).pointer.child) {
            const parent = self.parent.bindInput(input);
            return switch (kind) {
                .then => parent.then(State, self.state),
                .let_value => if (comptime continuation.kind(State) == .factory)
                    parent.letValue(State, self.state)
                else
                    parent.letValue(self.state, .{}),
                .upon_error => parent.uponError(State, self.state),
                .upon_stopped => parent.uponStopped(State, self.state),
                .let_error => parent.letError(State, self.state),
                .let_stopped => parent.letStopped(State, self.state),
                .starts_on => parent.startsOn(self.state),
                .continues_on => parent.continuesOn(self.state),
                .with_stop_token => parent.withStopToken(self.state),
                .bulk => parent.bulk(self.state.count, State.Callback, self.state.callback),
                .repeat_effect => parent.repeatEffect(),
                .repeat_until => parent.repeatEffectUntil(),
            };
        }
    });
}
