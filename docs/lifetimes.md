# Operation and borrowed-result lifetimes

**English** | [简体中文](lifetimes.zh-CN.md)

## Completion permits destruction

Start each operation once and deliver exactly one of `setValue(*const Values)`,
`setError(anyerror)`, or `setStopped()`. A receiver may destroy or reconstruct the
operation **inside this notification**, or keep it alive. Producers must finish
all operation accesses, unregister cancellation, and perform necessary cleanup
before notifying. No operation, embedded receiver, or parent access is permitted
thereafter. Caching a pointer does not keep its target alive.

`ex.connectInto(&operation, sender, receiver)` (`ex.connect` is an alias) constructs
`ex.Connection(S, R)` and its known children at their final addresses. Never copy
or move connected storage, even before start. A factory's dependent child connects
when its input becomes available. Storage stays stable until its owner destroys
or reconstructs it.

```zig
var operation: ex.Connection(@TypeOf(sender), @TypeOf(&receiver)) = undefined;
ex.connectInto(&operation, sender, &receiver);
operation.start(); // Synchronous completion may already have destroyed operation.
```

There is no `setFinished` notification or execution-scope acquire/release protocol.
Custom sources that access themselves after completion must migrate. This is a
breaking low-level protocol change; fluent composition, `syncWait`, and `spawn`
keep their call syntax.

## Owners may retain children and borrow results

Permission to destroy is not mandatory destruction. Successful tuples live in
operation storage, retained upstream operations, or externally owned storage with
an explicit lifetime. Published tuples remain valid and immutable while retained;
do not publish addresses of callback-local variables. Destruction or reconstruction
ends the corresponding borrow. Empty tuples may use static empty storage.

```zig
pub const Values = ex.Values(.{i64});
pub fn Operation(comptime R: type) type {
    return struct {
        receiver: ex.TypedReceiver(Values, R),
        output: Values = undefined,
        pub fn start(self: *@This()) void {
            self.output = .{42};
            self.receiver.setValue(&self.output); // Last operation access.
        }
    };
}
pub fn connectInto(_: @This(), out: anytype, receiver: anytype) void {
    out.* = .{ .receiver = .init(receiver) };
}
```

`letValue`/`upstream()`, `continuesOn`, and stop wrappers retain their children and
borrow results. They need no new payload copies for this protocol. `then` writes
new results into its output. Multi-input `whenAll` retains child/result pointers
and constructs one combined tuple; a single input forwards directly. Reusing a
union between stages would require preserving still-needed data first; current
let operations deliberately retain both stages.

`split` has independent shared-cache and subscription result storage. Pointer and
slice copies remain shallow. `syncWait` wakes on completion and copies its return
tuple before dropping local operation storage. Pointers within that tuple must
not refer to storage that disappears when syncWait returns.

## Asynchronous sources and concurrency

Completion can occur on another thread before `start()` returns. Once published,
a source must not access the operation without its own necessary coordination.
Queues synchronize publication. Schedulers detach tasks before execution and do
not inspect them afterward. I/O completes only after the kernel releases borrowed
buffers, cancellation callbacks are removed, and target/cancellation CQEs are drained.

There is no universal atomic execution reference count. Fan-in and racing
algorithms retain arrival counts protecting startup and cancellation dispatch.
Shared work retains genuine ownership references. `withStopToken` still coordinates
startup, cancellation, and completion. These synchronization requirements remain.

`repeat` composes each child with the shared TLS trampoline and may reconnect it
during completion; terminal results forward directly after child cleanup. Copy control
values before reconnecting, and never read the previous child afterward. Owners
store state that must survive iterations outside the reconstructed child.

## Associated resource cleanup

`Env.scope` now refers only to a resource cleanup registry (the compatibility name
is `Scope`). It has no active count, parent references, enter/leave, acquire/release,
or idle notification. Only algorithms registering resources, such as `associate`,
lock it. Ordinary I/O and scheduling do not count execution entries.

An association can protect resources borrowed by asynchronous downstream work.
The root detaches records and copies release actions onto the stack before calling
the final receiver, then releases those independent actions afterward. It never
reads destroyed operation storage. `whenAny` branches use the enclosing registry;
repeat has no private registry. At each storage-reuse boundary it cleans the
concrete child graph, and associated children remove their own enclosing-registry
records before entering the continuation. Removal is synchronized with other
branches. Stack use grows with the number of associations at that boundary.

Resource-owning custom operations used in repeat can implement
`pub fn cleanup(self: *@This(), continuation: anytype) void`. Detach owned state
before calling `continuation.run()` exactly once; that call may reconstruct or
destroy the operation. Any subsequent release must use independent local data.
Use `ex.cleanupOperation(&child, continuation)` or
`ex.cleanupOperations(.{ &next, &child }, continuation)` to forward cleanup through
initialized children. Uninitialized dependent children must be skipped. Cleanup
also runs for a connected child canceled before start. This hook handles storage
reuse, not execution counting; sources still perform their execution cleanup
before signaling completion. Operations without a hook need no reuse cleanup.

`spawn` frees its allocation in its completion receiver, then releases its independent
counting-scope association. Wait for that scope's `join()` before reclaiming resources
protected by it: observing value completion alone does not imply all external
associations have been released. Joining a counting scope from a graph still holding
an association to it would wait on itself.

## Typed environments

`ex.UnstoppableEnv` carries a zero-sized `NeverStopToken`; `ex.Env` retains a runtime
stop token. Built-in adaptors preserve `EnvOf(R)` instead of erasing every environment.
I/O/subscription/parent-stop callback storage disappears for never-stop environments.
`syncWait(.{})` and `spawn(..., .{ .allocator = allocator })` infer this environment;
explicit stop tokens retain cancellation. Manual receivers may declare:

```zig
pub fn getEnv(_: *@This()) ex.UnstoppableEnv { return .{}; }
```

`withStopToken` and sibling-canceling combinators still provide stoppable environments.
`readEnv()` returns a dynamic Env snapshot to preserve its static Values API. The
explicit legacy erased Receiver also erases environment types. Custom forwarding
receivers should return `ex.EnvOf(R)`, or explicitly use `.toDynamic()` when a
dynamic Env is intended.

Tests cover destroying the embedded receiver and connection during completion,
completion before start returns, synchronous/asynchronous repeat, retained 64 KiB
borrowed values, asynchronous association lifetimes, cancellation races, and I/O
address reuse. See `tests/completion_protocol.zig`, `tests/lifetime.zig`,
`tests/associate.zig`, `tests/repeat.zig`, and `tests/io_uring.zig`.
