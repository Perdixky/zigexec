# Type Constructors and Inference

**English** | [简体中文](types.zh-CN.md)

Prefer [fluent subexpressions](expressions.md) for complex pipelines and let the
library infer the complete graph. Explicit return types normally appear only in
application callbacks, with each factory naming the sender it directly returns:

```zig
const Duplicate = struct {
    pub fn call(_: @This(), value: anytype) ex.Just(.{ @TypeOf(value), bool }) {
        return ex.just(.{ value, true });
    }
};
const task = ex.just(@as(u16, 42)).letValue(
    ex.upstream().letValue(Duplicate, .{}),
    .{},
);
// task.Values is the tuple { u16, bool }.
```

There is no need to invent context, buffer, descriptor, or `undefined`
expressions merely to name a type. Constructors preserve static operation
layouts without dynamic sender erasure or additional allocation.

## Named types and type-level composition

```zig
fn number(value: i64) ex.Just(.{i64}) {
    return ex.just(value);
}

const Double = struct {
    pub fn call(_: @This(), value: i64) i64 { return value * 2; }
};
const Work = ex.Just(.{i64}).Then(Double).StartsOn(ex.ThreadPool.Scheduler);
```

Lowercase methods construct values; uppercase methods construct corresponding
types. `ex.Then(S, Callback)` and `S.Then(Callback)` are equivalent.
Callbacks are struct types; ordinary functions use `ex.Fn(function)`.

| Constructor | Parameters |
| --- | --- |
| `Values(.{i64, bool})` | Type list for a success/argument tuple |
| `Just(.{i64})`, `JustError(.{i64})`, `JustStopped(.{i64})` | Success type list; use `.{ }` for empty success |
| `Immediate(ValueTuple)` | Synchronous sender from a complete tuple type |
| `ReadEnv`, `ReadAllocator` | Concrete types with no arguments |
| `Then(S,F)`, `UponError(S,F)`, `UponStopped(S,F)` | Input sender and callback types |
| `LetValue(S,Target)` | Sender plus a factory, sender, or deferred-expression type |
| `LetError(S,F)`, `LetStopped(S,F)` | Sender and recovery factory type |
| `Bulk(S,F)` | Sender and callback; count is not part of the type |
| `Repeat(S)`, `RepeatUntil(S)` | Repeat empty success or until bool is true |
| `WhenAll(.{A,B})` | Sender type list; concatenates success arguments |
| `WhenAny(ContainerType)` | Tuple/named struct of senders; produces one tagged union |
| `Associated(S,Token)` | Explicit association owner; `.View` is the composable borrowed sender |
| `WithStopToken(S)` | Input sender |
| `Schedule(Scheduler)` | Scheduler type |
| `StartsOn(Scheduler,S)`, `ContinuesOn(S,Scheduler)` | Scheduler and sender types |
| `Shared(S)` | Owner type allocated explicitly by `split` |
| `Connection(S, R)` | Root storage initialized in place by `ex.connectInto(&op, sender, receiver)` |
| `Sender(Implementation)` | Fluent facade for a custom implementation |
| `Fn(function)` | Stateless callback type for a known function |
| `Bind(function, .{PrefixTypes...})` | Known function with bound prefix types |

`JustError` and `JustStopped` name the success type that would be possible,
not an error type. Their concrete types also distinguish completion capability.

`Just(.{i64})` matches both `just(21)` and `just(.{21})`. Untyped integer
literals materialize as `i64`; use `just(@as(u16, 21))` for another type.
`Values` is a convenience wrapper around `@Tuple`.

`ThreadPool.Scheduler` and `RunLoop.Scheduler` provide named scheduler types.
`asSender` is idempotent, and member/free scheduling forms do not introduce
different wrapper types.

## I/O types and backend specialization

```zig
const Io = ex.io.For(*ex.IoUring);

const ReadBack = struct {
    context: *ex.IoUring,
    fd: i32,
    buffer: []u8,
    pub fn call(self: @This(), written: usize) Io.ReadSome {
        return Io.readSome(self.context, self.fd, self.buffer[0..written], 0);
    }
};
```

Without a namespace, the same return type is
`ex.io.ReadSome(*ex.IoUring)`. Public types include `ReadSome`,
`WriteSome`, `Recv`, `Send`, `SendAll`, `SleepFor`, `OpenAt`,
`Close`, `Fsync`, `Accept`, `Connect`, and `Schedule(ContextPointer)`.
`io.For(ContextPointer)` fixes the context once and exposes the same types and
lowercase constructors.

These remain concrete operation types. Two senders that both produce `usize`
may have different layouts and are not interchangeable solely by result type.

## Specialization from upstream types

`then` and factory-form `letValue` use upstream `Values`. Error recovery
uses one `anyerror`, stopped recovery uses no argument, and bulk prepends a
`usize` index. Those types specialize generic `call` or `callTuple` methods
without executing a factory body.

```zig
fn twice(value: anytype) @TypeOf(value) { return value * 2; }
const task = ex.just(@as(u16, 21)).then(ex.Fn(twice), .{});
// The output value is u16.
```

Callback types, graph structure, reflection checks, and result types are known
at compile time. Runtime capture values do not become part of the type. A return
type must be derivable from function identity and argument types, not an
ordinary runtime field value.

`self` may be passed by value or pointer. Pointer `self` addresses persistent
operation storage and does not require the actual state to become comptime.
Complex chains belong directly in `letValue`; they need no duplicated
handwritten type expression.

## Optional prefix binding

Explicit callback fields are the normal capture mechanism. The lower-level
`Bind`/`bind` adapters can bind prefix arguments to an existing function:

```zig
fn multiply(factor: i64, value: i64) i64 { return factor * value; }
const callback = ex.bind(multiply, .{2});
const task = ex.just(21).then(@TypeOf(callback), callback);
```

Arguments are `prefix ++ upstream_values`. The function is compile-time known
while prefix values remain runtime state copied into the callback. Binding a
pointer does not extend its target's lifetime. Use a user wrapper when
specialization requires a concrete comptime value rather than merely its type.

## Associated-type queries

| Query | Result |
| --- | --- |
| `meta.ValuesOf(S)` | Complete success tuple |
| `meta.ValueOf(S)` | Sole success value; errors for zero or multiple values |
| `meta.OperationOf(S, R)` | Concrete `S.Operation(R)` for internal `sender.connectInto`; root storage is `Connection(S, R)` |
| `meta.WaitResult(S)` | `anyerror!?S.Values` |
| `meta.CallResult(Callback, ArgumentTuple)` | Callback result for an argument tuple |
| `meta.ReturnOf(function, .{ArgumentTypes...})` | Return type after specializing a known function/factory |

```zig
const Read = ex.meta.ReturnOf(ex.io.readSome, .{ *ex.IoUring, i32, []u8, u64 });
// Equivalent to ex.io.ReadSome(*ex.IoUring).
```

A deferred body has no independent `Values`. Given an input tuple, its concrete
sender is `@TypeOf(body).Bound(InputValues)`, though direct
`source.letValue(body, .{})` composition is normally clearer.

Queries do not execute function bodies. A factory requiring a concrete comptime
argument value cannot be specialized from argument types alone; fix that
argument first or use an explicit type constructor. Zig function boundaries
still require declared return types. Expression composition reduces that burden
to individual callback results instead of the entire graph.

`Just`, `JustError`, and `JustStopped` are now distinct concrete types so
`can_error` can distinguish their completion capabilities. `Immediate(Values)`
remains the general runtime completion-union sender and is conservatively fallible.
`RunInScope(Producer)` names the producer cleanup sender; both counting scopes
expose `Join`, `Token`, and `Association` types.
