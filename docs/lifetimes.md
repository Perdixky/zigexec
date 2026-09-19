# Operation Result Storage and Execution Scopes

**English** | [简体中文](lifetimes.zh-CN.md)

The fluent API remains unchanged: `then(Callback, args)`,
`letValue(target, args)`, and `syncWait(env)`. The lower-level
sender/receiver protocol now references completion values and distinguishes
logical completion from safe retirement. This intentionally strengthens the
lifetime contract beyond P2300's rule that permits operation destruction inside
a value, error, or stopped completion callback.

## Two completion moments

`setValue(*const Values)`, `setError(anyerror)`, and `setStopped()` publish
exactly one logical result. At that point the root connection must not be
destroyed, moved, or reconstructed, and resources still used by the producer
must remain alive.

`ex.connect(sender, &receiver)` returns `ex.Connection(SenderType)`. It embeds
the raw `SenderType.Operation` and an execution scope and must remain at a
stable address after start. Once every execution entry exits, the root
receiver's optional `setFinished()` is called exactly once. The connection may
then be retired, including from `setFinished` itself. The dispatcher never
accesses that connection afterward.

A manual receiver without `setFinished` needs an external proof that execution
has exited, for example after a driving `RunLoop.run()` returns. Merely
observing `setValue` is insufficient. Custom receivers should normally use
`setFinished` to notify their owner.

`syncWait` uses a root connection and returns only after `setFinished`.
Successful tuples are copied out of the scope. Pointers and slices inside that
tuple do not extend the referenced object's lifetime and must not expose
operation-internal storage to the caller.

## Result storage

A successful value must live in the operation itself, in an upstream operation
within the same execution scope, or in external storage known to outlive the
scope. It cannot be modified after publication. Never pass a receiver the
address of a callback-local tuple.

```zig
pub const Values = ex.Values(.{i64});
pub const Operation = struct {
    receiver: ex.Receiver(Values),
    output: Values = undefined,
    pub fn start(self: *@This()) void {
        self.output = .{42};
        self.receiver.setValue(&self.output);
    }
};
```

`then` writes application results into its own output slot. `letValue` and
`upstream()` borrow upstream results instead of copying inputs or constructing
a `just` sender containing the same tuple. `continuesOn` and
`withStopToken` retain result pointers. `whenAll` retains branch pointers and
constructs contiguous completion-argument storage after every branch succeeds.
Callbacks receive its elements as separate arguments; `syncWait` copies the
argument tuple out as its return value.

`split` is a separate ownership boundary: shared state contains a cache, and
each subscription operation stores its own result so asynchronous downstream
work does not depend on a released owner. Pointers and slices remain shallow
copies, and the library never frees user resources automatically.

Callback argument types do not change. Ordinary by-value `call` or
`callTuple` may still copy. The framework avoids redundant payload copies
during forwarding but does not promise zero copies in arbitrary application
code or sender construction. Whether a producer writes directly into its output
slot also depends on Zig's backend.

## Protecting asynchronous entries

`Env.scope` is the execution-lifetime service. Ordinary nodes forward it.
A custom asynchronous sender acquires an entry before publishing work and
releases it after its final operation access:

```zig
// Before submitting work to another thread or backend:
const scope = self.receiver.getEnv().scope;
ex.Scope.acquire(scope);
// submit(self); a failure path must publish an error and release(scope).

// In the corresponding completion entry:
const scope = self.receiver.getEnv().scope;
// Store the result, unregister cancellation, notify, and finish local cleanup.
self.receiver.setValue(&self.output);
// Every operation access must finish before release.
ex.Scope.release(scope);
```

Every acquire must have one release, and no operation memory may be accessed
after release. Root `start` already holds an entry, so ordinary synchronous
nodes do not increment the counter individually. Scheduler tasks, I/O
completions, shared subscriptions, and cancellation paths that can cause
completion are protected. A custom asynchronous producer that fails to acquire
an entry violates the protocol and can trigger assertions in Debug or
ReleaseSafe builds when the root scope becomes idle.

The acquire/release synchronization makes stored results and completion state
visible to `setFinished` after the final entry exits. A scope does not allocate,
but asynchronous entries use atomic counting and therefore add synchronization
cost; this is not a claim that every workload becomes faster.

Each `ex.connect` creates an independent root. An existing `Env.scope` does
not make another root its implicit owner. Low-level
`sender.connect(Receiver)` returns a raw operation for composition internals;
manual users must supply a scope and obey the storage rules.

## Loops and storage reuse

`repeatEffect` creates a child scope for each round while its parent scope
keeps the overall loop alive. The next connect/start may overwrite child
operation storage only after that round logically completes and every execution
entry exits. A synchronous 100,000-round loop still uses a trampoline, and
asynchronous rounds do not grow the call stack recursively. State shared across
rounds belongs outside the loop behind an explicit pointer.

## Verification

`tests/lifetime.zig` covers address stability and operation size for a 64 KiB
payload through nested `upstream`/`letValue`, scheduling, and cancellation
wrappers; `then` result placement; a producer that continues using its
operation after `setValue`; delayed `setFinished`/`syncWait`; repeat storage
reuse; and subscriptions that survive early shared-owner release.

`tests/codegen/receiver_forward.zig` inspects optimized IR across a real
`Receiver` function-pointer boundary:

```sh
zig build-obj -O ReleaseSafe --dep zigexec \
  -Mroot=tests/codegen/receiver_forward.zig -Mzigexec=src/root.zig \
  -fno-emit-bin -femit-llvm-ir=/tmp/zigexec-receiver-forward.ll
```

On the tested Zig 0.17 master x86_64 LLVM backend, the 64 KiB tuple is forwarded
by pointer without a payload memcpy or temporary array in the forwarding
function. This is not a benchmark for the complete graph.

`tests/codegen/operation_layout.zig` compares layouts before and after the
change. A 64 KiB `just` payload nested through `letValue`/`upstream`,
`continuesOn`, and `withStopToken` shrank from **721,592 bytes to 197,544
bytes**, about 72.6%, for the raw composed operation on x86_64. It excludes the
root `Connection` wrapper and does not claim that every construction-time copy
was removed.

```sh
zig run -O ReleaseSafe --dep zigexec \
  -Mroot=tests/codegen/operation_layout.zig -Mzigexec=src/root.zig
```


## Associations and branch retirement

`associate` registers a release action in the current execution scope. At idle,
the dispatcher extracts actions before `setFinished` can free operation records,
then releases counting-scope associations afterwards. `whenAny` observes each
branch's execution retirement independently, but forwards its association records
to the enclosing scope so asynchronous downstream consumers remain protected.
`repeatEffect` iterations have their own storage-reuse boundary. See
[counting scopes](counting_scopes.md) and [concurrent results](combinators.md).
