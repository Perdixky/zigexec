# Concurrent results: tuples and unions

**English** | [简体中文](combinators.zh-CN.md)

`whenAll` concatenates completion arguments; `whenAny` sends one tagged union.
Their result shapes are known at compile time, and neither algorithm allocates
heap memory itself. Ordinary `then` and `letValue` return conventions do not change.

## whenAll: concatenate completion arguments

```zig
const Add = struct {
    pub fn call(_: @This(), left: i64, right: i64) i64 {
        return left + right;
    }
};
const task = ex.whenAll(.{ ex.just(20), ex.just(22) });
const answer = (try task.then(Add, .{}).syncWait(.{})).?[0]; // 42
const pair = (try task.syncWait(.{})).?; // .{ 20, 22 }
```

Like [P2300's when_all](https://eel.is/c++draft/exec.when.all), each branch's
success arguments are concatenated in input order and passed separately to the
next `then` callback or `letValue` factory. For example:

```zig
const result = (try ex.whenAll(.{
    ex.just(@as(i64, 20)),
    ex.just(.{ true, @as(u8, 22) }),
}).syncWait(.{})) orelse return;
// result: tuple { i64, bool, u8 }, with values .{ 20, true, 22 }.
// A downstream call would accept (self, number: i64, flag: bool, byte: u8).
```

`syncWait` packages the completion arguments as its returned tuple. Internally,
`SenderType.Values` also represents those arguments as a tuple for stable
operation storage and the `setValue(*const Values)` protocol. That storage tuple
is not an extra tuple-valued argument: ordinary `call` expands it into parameters.
`callTuple(self, values)` remains available to explicitly receive all arguments
as one tuple.

Empty branches contribute no arguments; `whenAll(.{})` completes with zero
arguments, and `syncWait` returns a non-null empty tuple. Nested `whenAll` also
concatenates arguments. A tuple deliberately returned as one value by a `then`
callback stays one value; its fields are not recursively expanded.

All branches start. An error or stopped completion requests sibling cancellation;
the aggregate waits for every branch's completion. Errors take precedence over
stopped, reporting the first observed error. All branch completion and cancellation
coordination finishes before forwarding. The receiver may destroy the graph then.

`ex.WhenAll(.{ A, B })` names the sender type. `ex.meta.ValuesOf(SenderType)`
(or `SenderType.Values`) describes the complete success argument tuple.
`meta.ValueOf` applies only when there is exactly one success argument.

## whenAny: one tagged union

```zig
const race = ex.whenAny(.{
    .read = ex.io.recv(context, socket, buffer, 0),
    .timeout = ex.io.sleepFor(context, 5 * std.time.ns_per_s),
});
const Handle = struct {
    pub fn call(_: @This(), result: ex.meta.ValueOf(@TypeOf(race))) !usize {
        return switch (result) {
            .read => |values| values[0],
            .timeout => error.Timeout,
        };
    }
};
const bytes = (try race.then(Handle, .{}).syncWait(.{})) orelse return;
```

Named input fields become union tags. Each payload is that branch's **complete
success tuple**, including a one-element tuple for a scalar or an empty tuple
for a timer. Tuple inputs also work, with tags `.@"0"`, `.@"1"`, etc.
Use named inputs when switching on the result.

The **first completion channel** wins: value, error, or stopped. A value produces
the union; error and stopped use the usual separate receiver channels. Later
errors do not replace an earlier success. Ties follow observed callback order;
there is no fairness guarantee, and inline branches start in declaration order.
All branches are started, including branches whose stop token is already set.

After selecting a winner, the algorithm requests stop on the other branches
and waits for **every branch to complete** before invoking downstream.
A recv-versus-timer race therefore drains the cancelled kernel request before
downstream code can reuse its buffer. A noncooperative loser can delay completion
indefinitely: this is structured cancellation, not detached work or a hard timeout.
External stop requests are cooperative too; they do not overwrite a winner.

The generated type is `ex.WhenAny(ContainerType)`, where `ContainerType` is a
named struct or tuple **of sender types**. For example:

```zig
const Io = ex.io.For(*ex.IoUring);
const Race = ex.WhenAny(struct { read: Io.Recv, timeout: Io.SleepFor });
const Result = ex.meta.ValueOf(Race);
```

An empty input or non-sender branch is rejected at compile time. Neither
algorithm converts a callback's returned tuple or union into a sender graph.
A `then` callback returning a tuple or tagged union sends that object as one
ordinary value; a `letValue` factory still returns a sender or `!sender`.

## Ownership boundaries

The final aggregate is materialized in operation storage. Pointer and slice
members remain borrowed; copies do not extend pointee lifetimes. `whenAny`
keeps embedded branch storage and associated resources alive through downstream
consumption, even after individual branch execution has ended. `repeat`
cleans the concrete child graph at each iteration boundary, letting associated
children detach their own cleanup actions.

Neither algorithm destroys application resources automatically. A losing
successful branch may have opened a file or accepted a socket, and `whenAll`
can discard successful values if another branch fails. Arrange resource cleanup
inside those branches or use explicit owners that outlive the complete graph.
Returning operation-internal pointers from `syncWait` is invalid, since the
operation is gone when the call returns.
