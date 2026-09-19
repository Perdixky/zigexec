# Counting scopes and dynamic tasks

**English** | [简体中文](counting_scopes.zh-CN.md)

The design follows the current C++ working draft's
[counting scopes](https://eel.is/c++draft/exec.counting.scopes) and
[spawn](https://eel.is/c++draft/exec.spawn). Scope association, allocation,
scheduling, and application failure policy are separate responsibilities.

| API | Responsibility |
| --- | --- |
| `SimpleCountingScope` | Count associations, close admission, asynchronously join |
| `CountingScope` | The same lifecycle, plus cooperative `requestStop()` |
| `scope.getToken()` | Borrow a token that can wrap senders and acquire associations |
| `ex.spawn(sender, token, env)` | Allocate, start, and reclaim an independent task |
| `ex.runInScope(&scope, producer)` | Zig extension: close/drain after producer success, cancel/drain after producer error or stop |

Neither counting scope owns an allocator, scheduler, or task result. They create
no threads and perform no heap allocations themselves. `Scope` remains the
separate internal execution-entry tracker for operation lifetimes.

```zig
var scope: ex.CountingScope = .{};
defer scope.deinit();

try ex.spawn(
    ex.schedule(scheduler)
        .letValue(Work, .{state})
        .uponError(HandleError, .{}), // call returns void, handles all task errors
    scope.getToken(),
    .{ .allocator = allocator },
);
scope.close();
_ = try scope.join().syncWait(.{});
```

## Lifecycle

- `getToken()` returns a borrowed, copyable handle. `token.wrap(sender)` does not
  acquire an association. Simple scope wrapping preserves the sender; counting
  scope wrapping combines the scope's stop source with receiver cancellation.
- `token.tryAssociate()` returns an explicit `Association`. `isEngaged()` checks
  success; `take()` transfers ownership and empties the source; `tryAssociate()`
  on an engaged association attempts to acquire another independent association.
  Call `deinit()` once for each acquired association. Zig assignment is a shallow
  copy, **not** an ownership clone. Spawn manages these handles internally.
- `close()` rejects subsequent associations. It does not cancel existing work.
- `requestStop()` requests cancellation but does not close admission. Future
  associated tasks see the already-requested token too. A child completing with
  stopped does not stop its siblings or change admission.
- Calling or connecting `join()` has no lifecycle effect. Starting it enters
  joining; while open and associations remain, further spawn is allowed. At zero
  associations the scope becomes permanently joined and rejects new work.
  Multiple join waiters and subsequent joins of an already-joined scope work.
- `deinit()` neither cancels nor waits. It asserts that the scope is unused,
  unused-and-closed, or joined. A previously used scope whose count happens to be
  zero still needs join. Keep its address stable and finish accessing tokens,
  associations, and scope methods before destroying it.

An open joining scope is useful for recursive work: an associated parent can
spawn its children before releasing its own association. When an external
producer must prevent early join, hold an association for its lifetime.

## Join scheduling

An already-empty join completes inline with value. A pending join schedules its
completion using `receiver.getEnv().getStartScheduler()`. It never collects task
results, and does not request cancellation of scope children when its own receiver
is cancelled. After draining, the scheduler may report value, error, or stopped.

`syncWait(.{})` supplies and drives a local RunLoop as the default start scheduler;
join continuations resume on the waiting thread. Custom receivers can set:

```zig
const scheduler = context.getScheduler();
const env: ex.Env = .{
    .start_scheduler = ex.StartScheduler.init(&scheduler),
};
```

`StartScheduler` borrows a stable scheduler pointer and erases only its
`submit(*ex.ScheduleTask) !void` entry point; it does not allocate. Inline, RunLoop,
ThreadPool, and IoUring schedulers support this boundary. A custom submitter must
execute each accepted task exactly once; after reporting submission failure it
must never execute the task. Keep the scheduler alive through operation retirement.
This adapter is separate from the ordinary generic `schedule()` sender protocol.
A missing start scheduler is reported as `MissingStartScheduler` **after** draining,
so an invalid runtime environment cannot abandon live children. Scheduler handles
read from a syncWait-provided Env must not escape the wait's lifetime.

## Spawn ownership and error checking

`spawn` requires an empty success tuple and `can_error = false`. Built-in
composition infers this conservative property at compile time: `then` accounts
for callback errors; `letValue` accounts for factory and child errors;
`uponError` removes upstream errors only if its handler is infallible; scheduling
can introduce new errors. Handle errors after all fallible stages. A custom sender
without metadata is treated as potentially fallible. It may explicitly declare
`pub const can_error = false` as a protocol contract; violating it panics.
This is an error-capability check, not full C++ completion-signature reflection.

Allocation comes only from the explicit `env.allocator`; there is no global
fallback. `MissingAllocator`, `OutOfMemory`, or `ScopeClosed` means the sender was
not started and the caller still owns resources intended for transfer. The latter
also represents association-limit rejection. Unlike C++ spawn's silent admission
rejection, Zig exposes refusal so a newly accepted socket can be closed reliably.
An association is reserved before allocation to protect the allocator itself;
a failed allocation may therefore leave a used scope requiring join.

The task owns an independent root `Connection`, not the caller's `Env.scope`.
Pointer/slice captures stay borrowed; never capture reused accept-iteration
storage. Reclamation occurs in this order:

1. Publish task completion.
2. Wait for every execution entry to leave; invoke root `setFinished`.
3. Free task/operation storage using the explicit allocator.
4. Release the association, allowing join to complete.

CountingScope additionally guards cancellation dispatch, so synchronous child
retirement cannot destroy its stop source during `requestStop()`. Concurrent
spawn/completion/cancellation is supported with a concurrent allocator. Join
protects associated resources; it does not join arbitrary external method-calling
threads. Coordinate those callers before destruction.

## Producer policy and TCP echo

`runInScope(&scope, producer)` is a separate, single-producer lifecycle helper for
an explicitly owned `CountingScope`, not a standard scope member. The producer
must have empty success values. It waits for producer retirement, closes admission,
then joins. Producer error/stop or outer cancellation requests scope cancellation;
producer success drains normally. It preserves producer errors through cleanup.
Child errors remain the responsibility of each spawned chain. Let this helper
manage joining; do not race an independent join against the producer's startup.

[The echo example](../examples/tcp_echo.zig) has exactly one outstanding accept:

```zig
const accept_loop = Io.accept(context, listener, linux.SOCK.CLOEXEC)
    .then(SpawnEcho, .{ &scope, allocator, context, once })
    .repeatEffectUntil();
_ = try ex.runInScope(&scope, accept_loop).syncWait(.{});
```

Each accepted socket starts a child beginning with
`ex.schedule(context.getScheduler()).letValue(Echo, ...)`. All children use the
same io_uring context, with separate operation-owned 16 KiB buffers. The producer
immediately resumes accepting. One final syncWait covers the whole service;
`--once` stops acceptance after one spawn and waits for that child normally.
Socket cleanup covers completion, cancellation, scheduling failure, and spawn
failure. The example has no connection limit or signal handler: memory grows with
live connections, and process termination is not cooperative scope shutdown.

This implements the counting/association/spawn model, not all async-scope APIs:
`spawnFuture` is not yet provided.


## Associate: lazy work with explicit ownership

```zig
var scope: ex.CountingScope = .{};
defer scope.deinit();
var owner = ex.associate(ex.just(42), scope.getToken());
defer owner.deinit();
scope.close();
const result = try owner.takeSender().syncWait(.{});
_ = try scope.join().syncWait(.{});
```

`sender.associate(token)` is equivalent. Association is eager; execution stays
lazy. No allocator is needed. This returns an explicit owner rather than a
copyable owning sender: Zig has neither automatic destructors nor move constructors.

- `isEngaged()` reports admission. Rejection produces a disengaged owner whose
  view completes stopped without starting the wrapped sender.
- `sender()` returns a borrowed composable view. Starting a view attempts a fresh
  operation association; a closed scope refuses it. The original owner remains
  engaged, so release it before waiting for join.
- `takeSender()` also returns a borrowed view, but start transfers the owner's
  existing association. Previously admitted work can therefore start after close.
  The first start empties the owner; further starts complete stopped.
- `take()` moves the owner explicitly and empties its source. `clone()` attempts a
  separate association and can be refused after close. Never shallow-copy owners
  and deinitialize both copies.
- `deinit()` releases an unused owner. Creating, connecting, or abandoning an
  unstarted view acquires nothing and does not consume the owner's association.
  Keep the owner at a stable address until every borrowed view that will run has
  started. Afterwards operation associations are independent of the owner.

Acquisition/transfer occurs at **start**, unlike C++ associate's owning sender
and connect-time operation association. This deliberate Zig adaptation prevents
unstarted generic operation graphs from leaking associations. Mutating the same
owner (`take`, `takeSender` start, or `deinit`) needs external synchronization.

A started association remains engaged until the containing execution scope
retires, including asynchronous downstream borrowing. Retirement first extracts
release actions, then permits root `setFinished` to reclaim operation memory,
then releases associations. A `whenAny` branch's execution ending is not enough:
its records belong to the enclosing graph. Repeated iterations instead release
at their own storage-reuse boundary. Do not join a scope from inside a graph
holding an association to that scope: the join would wait for itself.

The retirement path allocates no heap memory. It copies pending release actions
onto the completion thread's stack before reclaiming their embedded records;
stack usage grows with associations retiring at that boundary. Raw internal
connect usage requires a valid execution scope, otherwise the view reports
`MissingExecutionScope`. Prefer public `ex.connect` or `syncWait`.
