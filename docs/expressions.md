# Fluent Expressions, Explicit State, and Compile-Time Callbacks

**English** | [简体中文](expressions.zh-CN.md)

The public API centers on callback **types** and explicitly captured state:

```zig
const task = source.letValue(
    ex.upstream()
        .letValue(SendRequest, .{ config, client })
        .then(Decode, .{})
        .then(AddOffset, .{offset}),
    .{},
);
```

`SendRequest`, `Decode`, and `AddOffset` are struct types with a
`pub fn call`, not struct instances. `args` initializes their fields and the
upstream values follow `self` in the call. A handwritten factory declares only
the sender it directly returns; the library infers the complete expression type.

## Core operations and three continuation forms

| API | Meaning |
| --- | --- |
| `ex.upstream()` | Start of an unbound subexpression representing the nearest `letValue` success |
| `.then(Callback, args)` | Initialize captures, run synchronous `call`, and forward its result |
| `.letValue(Factory, args)` | Initialize captures, invoke a sender factory, and await that sender |
| `.letValue(body, .{})` | Borrow the upstream operation's result and bind an `upstream()` expression |
| `.letValue(child, .{})` | Start an already-constructed sender after upstream success without injecting values |

The relevant signatures are:

```zig
then(self, comptime Callback: type, args: anytype)
letValue(self, target: anytype, args: anytype)
```

Zig cannot overload a method by arity, so both forms consistently take two
arguments. A factory **type** is implicitly comptime and `args` initializes its
fields. A sender or expression **value** preserves runtime state and requires
empty `.{ }` arguments. Compile-time reflection selects the form without
runtime dispatch or type erasure. Factory instances, sender types, invalid
targets, and extra captures for value targets receive explicit diagnostics.

An existing sender's construction expression is evaluated immediately; only
`connect` and `start` are delayed. Use a factory when construction itself
must occur after upstream success. All continuation forms are skipped on
upstream error or stopped and forward that completion unchanged. A child
sender's own value, error, or stopped completion continues downstream.

A deferred `body` is **not comptime** because it may contain runtime
configuration, clients, or offsets. Its type, graph, callback identity,
input/output types, and operation layout are compile-time facts; captured field
values remain runtime state.

An expression is not a bound sender and cannot be connected or waited directly.
`source.letValue(body, .{})` binds its input and produces concrete `Values`
and `Operation` types. In nested scopes, an inner `upstream()` binds only the
nearest `letValue`; that inner result then continues through the outer graph.

## Struct captures and application code

```zig
const AddOffset = struct {
    offset: i64,
    pub fn call(self: @This(), value: i64) i64 {
        return self.offset + value;
    }
};

const Io = ex.io.For(*ex.IoUring);
const SendRequest = struct {
    context: *ex.IoUring,
    socket: i32,
    pub fn call(self: @This(), request: []const u8) Io.Send {
        return Io.send(self.context, self.socket, request, 0);
    }
};
```

Captures support positional and named initialization:

```zig
.then(AddOffset, .{offset})
.then(AddOffset, .{ .offset = offset })
```

A nonempty positional tuple supplies every field. Named initialization can use
field defaults, and `.{ }` selects all defaults. A constructed callback value
may also be passed as `args`. Field types come from the callback, allowing
literals to coerce naturally. Captures are copied by value; pointer captures
copy only the address and make shared mutable state explicit.

Conceptually the call is `Callback{captures}.call(upstream...)`. `self` may
be a value, pointer, or const pointer. A pointer receiver refers to callback
storage inside the operation, not a temporary copy.

A `then` returning `void` or `!void` produces an empty success tuple;
`T` or `!T` produces one value. A `letValue` factory returns `Sender` or
`!Sender`, and downstream values come from that sender. Returned errors enter
the error channel, while child stopped remains stopped.

`uponError`, `uponStopped`, `letError`, `letStopped`, and `bulk` use the
same callback and explicit-state model:

```zig
sender.uponError(Recover, .{state})
sender.letError(Retry, .{client})
sender.bulk(count, Fill, .{buffer})
```

Recovery must preserve the original success tuple type. Error callbacks receive
one `anyerror`, stopped callbacks receive no input, and bulk callbacks receive
a `usize` index before the upstream values. Scheduling, stop-token wrappers,
and [repetition](repeat.md) all compose inside deferred expressions.

## Storage and asynchronous borrowing

Construction stores state but runs no application logic. After `start`, an
upstream operation stores its success tuple and the child scope borrows that
address instead of saving another input copy. Operations must remain at stable
addresses. The root connection retains storage until completion handlers leave
their execution entries, then `setFinished` permits retirement. See the
[lifetime protocol](lifetimes.md).

`upstream()` forwards tuple storage by reference inside the framework while
application callback parameters retain their declared types. Allocate dynamic
buffers explicitly and pass slices across asynchronous boundaries. Copying a
slice preserves the allocation address, but its owner must keep that allocation
alive and eventually release it.

```zig
const Write = struct {
    context: *ex.IoUring,
    file: i32,
    pub fn call(self: @This(), buffer: []const u8) Io.WriteSome {
        return Io.writeSome(self.context, self.file, buffer, 0);
    }
};

const buffer = try allocator.alloc(u8, 4096);
defer allocator.free(buffer);
@memset(buffer, 0);
const task = ex.just(buffer).letValue(
    ex.upstream().letValue(Write, .{ context, file }),
    .{},
);
_ = try task.syncWait(.{ .allocator = allocator });
```

Ownership, allocation source, and borrowing are separate concerns. A common
allocator does not imply automatic cleanup, and `letValue` does not take
ownership of a user buffer. Inline arrays are copied by value and an asynchronous
task must not borrow the address of a callback-stack copy.

A callback may lend one of its own fields when it uses pointer `self`:

```zig
const Read = struct {
    context: *ex.IoUring,
    file: i32,
    buffer: [4096]u8 = undefined,
    pub fn call(self: *@This()) Io.ReadSome {
        return Io.readSome(self.context, self.file, &self.buffer, 0);
    }
};
```

A value receiver or factory-local array cannot be lent this way. Copying an
external pointer or slice never extends the underlying resource lifetime.
Internal borrows must not escape operation destruction. In particular, a
`syncWait` result must not expose a pointer into its completed operation;
consume it inside the chain or copy it into externally owned storage. The
library does not call user `deinit`, deep-copy resources, or close descriptors.

## Generics and ordinary functions

Callbacks may use `anytype`; the library specializes `call` from upstream
types. A `callTuple(self, args: anytype)` can accept the complete tuple and
takes precedence when both methods exist. Application functions still declare
their own return types.

`Fn` adapts a stateless ordinary function while preserving its compile-time
identity:

```zig
fn twice(n: anytype) @TypeOf(n) { return n * 2; }
const task = ex.just(@as(u16, 21)).then(ex.Fn(twice), .{});
// The result remains u16; there is no runtime function pointer.
```

A runtime function pointer can instead be an explicit callback field and be
invoked by `call` when dynamic behavior is genuinely required.

## Compile-time diagnostics

Bound senders are checked when composed. Checks that depend on a deferred
expression's input run when it is attached to `letValue`; no execution is
needed.

```zig
const Length = struct {
    pub fn call(_: @This(), text: []const u8) usize { return text.len; }
};
const bad = ex.just(42).then(Length, .{});
```

The first diagnostic identifies the node, callback, argument index, and types:

```text
error: zigexec.then: wrong_input.Length.call upstream argument 0: expected []const u8, got i64
```

Dedicated checks cover callback methods and `self`, argument counts, common
input incompatibilities, capture field names/counts/required fields/types, and
factory sender protocols. Zig still diagnoses generic bodies, value-dependent
coercions, and complex structural conversions. `zig build test-errors` checks
expected failures, and `zig build test-all` includes those checks.

## Migration from the old API

| Old | Current |
| --- | --- |
| `.then(AddOffset{ .offset = n })` | `.then(AddOffset, .{n})` |
| `.then(double)` | `.then(ex.Fn(double), .{})` |
| `.letCall(Factory, args)` | `.letValue(Factory, args)` |
| `.letValue(body)` | `.letValue(body, .{})` |
| Handwritten callback returning a complete chain | `.letValue(ex.upstream().letValue(Factory, args).then(Transform, .{}), .{})` |
| `LetCall(S, Factory)` | `LetValue(S, Factory)` |

No compatibility aliases remain. `LetValue(S, Target)` accepts a factory,
existing sender, or deferred-expression type and matches the concrete type
created by the corresponding value form. See the [type API](types.md).

## Execution allocator

The optional allocator belongs to `Env`, which ordinary chains forward.
Senders query `receiver.getEnv().getAllocator()` and handle
`error.MissingAllocator`; application code may use `readAllocator()`.
Configure it through `syncWait(.{ .allocator = allocator })` or a custom
receiver. It standardizes allocation sources without moving values to the heap
or automatically freeing owning results. See
[allocators and ownership](allocators.md).
