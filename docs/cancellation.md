# Cancellation Protocol

**English** | [简体中文](cancellation.zh-CN.md)

`StopSource`, `StopToken`, and `StopCallback` implement cancellation
independently of `std.Io`. A source contains a one-shot stop flag and an
intrusive callback list. Tokens borrow the source, and callback nodes are
provided by callers, so registration does not allocate.

## Lifetime and threading semantics

- A `StopSource` must not move after use begins.
- `source.token()` returns a copyable borrowed handle; an empty token never
  stops.
- A registered `StopCallback` must not move or be copied.
- The source must outlive every callback `deinit()` and every active
  `requestStop()`. Tokens do not retain the source.
- In safe builds, `source.deinit()` verifies that no registration or callback
  invocation remains. Triggered registrations must still be unregistered.
- The winning `requestStop()` sets the flag and invokes callbacks
  synchronously. Later calls return `false` and do not wait for the winner.
- Registration on an already-stopped source invokes the callback before
  `init()` returns, so callers must permit reentrancy.
- Unregistering removes a callback that has not started. If another thread is
  invoking it, `deinit()` waits for that invocation.
- A callback may unregister and free itself, manage other registrations, or
  request stop again. It must not destroy a source whose `requestStop()` is
  still active.
- One callback's initialization and destruction must be serialized by its
  owner; thread safety does not permit two threads to destroy the same node.

Callbacks execute outside the source lock. They may run on the thread requesting
stop or on a thread registering against an already-stopped source. They should
return promptly and must not block on a path that depends on their own
unregistration. Different callbacks may run concurrently and have no guaranteed
order.

## Unregistration and self-destruction

Before dispatch, the implementation creates an invocation record containing the
executing thread ID and associates it with the callback. Self-destruction marks
that invocation so dispatch never touches the freed node afterward.
Cross-thread unregistration waits on a condition until the invocation ends.

This avoids two common failures: calling user code while holding the source lock,
which can deadlock under reentrancy, and writing to a callback node after that
callback freed itself.

## Forwarding through algorithms

An environment token borrows one source. `withStopToken` creates an internal
source and registers forwarding callbacks on both the supplied token and the
downstream token. `whenAll` similarly uses an internal source and forwards
downstream cancellation.

Forwarding can synchronously complete an entire subgraph. The forwarding
callback therefore retains a temporary completion reference while requesting
stop. When the reference count reaches zero, forwarding registrations are
removed before the final receiver is notified. An operation that has begun
completion cannot acquire a new reference. Together with `whenAll`'s startup
reference, this keeps the source and startup loop alive.

## Cancellation is not preemption

`just` always sends its value; `then` cannot interrupt a function already
running. `bulk` and queued scheduling provide explicit checkpoints. Long CPU
operations must still inspect the token themselves.

An io_uring cancellation callback only marks a request and writes to eventfd.
The reactor submits `IORING_OP_ASYNC_CANCEL` and sends stopped only after the
kernel has completed the actual request. Cancellation races normal completion,
so an I/O that already completed may still send a value.
