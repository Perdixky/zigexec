# Repetition

**English** | [简体中文](repeat.zh-CN.md)

## repeat

```zig
const task = effect.repeat();
```

The effect must complete successfully with an **empty tuple**. After every
success the algorithm reconnects and starts the same sender description.
Error and stopped terminate the repetition unchanged. `repeat` itself
never succeeds, so it is normally paired with cancellation or a sentinel error
that is recovered according to application semantics.

```zig
const Tick = struct {
    count: *usize,
    pub fn call(self: @This()) void { self.count.* += 1; }
};
const task = ex.just(.{}).then(Tick, .{&count}).repeat();
_ = try task.syncWait(.{ .allocator = allocator, .stop_token = source.token() });
```

This synchronous loop needs another thread to request stop. The token is checked
before each round; an asynchronous child already running still finishes through
its own cancellation protocol and is never simply discarded.

## repeatUntil

```zig
const Tick = struct {
    count: *usize,
    limit: usize,
    pub fn call(self: @This()) bool {
        self.count.* += 1;
        return self.count.* == self.limit;
    }
};
const task = ex.just(.{}).then(Tick, .{ &count, 100 }).repeatUntil();
_ = try task.syncWait(.{ .allocator = allocator });
```

The effect must produce exactly **one bool**: false repeats, while true
terminates with an empty successful tuple. It runs at least once unless already
cancelled. Error or stopped terminates immediately, and type mismatches receive
a dedicated compile-time diagnostic.

Both algorithms have free functions, fluent sender methods, deferred-expression
methods, and `Repeat(S)` / `RepeatUntil(S)` type constructors.

## State, scheduling, and lifetime

Each reconnection creates a child operation from the original sender
description, reinitializing callback captures stored by value. State that must
survive rounds belongs behind an explicit pointer or stable external owner.
Allocator and stop token are forwarded from the final receiver.

Repetition shares the thread-local `TrampolineScheduler` across sender types and
nested repeats. Nested submissions execute inline up to the outermost scheduler's
limits (16 levels and 4096 bytes of stack distance by default), then enter an
intrusive FIFO drained by that outer call. These limits apply at scheduling
points, not to stack usage inside a user callback. There is no per-repeat atomic
work counter.

Following stdexec's `repeat_until`, each child is composed with
`startsOn(TrampolineScheduler{})`. The first child connects eagerly; completion
cleans up that child, reconnects the scheduled chain, and starts it again.
The scheduler checks cancellation before starting each effect, including queued
iterations. Terminal results forward directly after cleanup.

There is no iteration `Scope`, resource registry, or execution reference count
inside repeat. Its receiver forwards the environment unchanged. Cleanup follows
the concrete child operation graph; `associate` detaches its own record from the
enclosing connection and keeps an independent release action across the
continuation. Ordinary children require no registry access. The source must not
access itself after completion, including when another thread completes before
start returns. Custom resource-owning operations can implement
`cleanup(self, continuation)`; see [operation lifetimes](lifetimes.md).

`ex.TrampolineScheduler{ .max_depth = 16, .max_stack_bytes = 4096 }` also works
with `schedule`, `startsOn`, and `continuesOn`. Nested scheduler instances use
the outermost instance's limits. `repeatEffect` / `repeatEffectUntil` and their
capitalized type constructors remain compatibility aliases; new code should use
`repeat` / `repeatUntil`.

Repetition does not change threads or insert a scheduling point. A purely
synchronous infinite effect monopolizes the current thread; include a scheduler
inside the effect when fairness is needed. A normal io_uring effect returns
execution while waiting for I/O.

## TCP echo and short writes

The [echo example](../examples/tcp_echo.zig) uses this per-connection loop:

```zig
const body = Io.recv(self.context, self.socket, &self.buffer, 0)
    .letValue(EchoChunk, .{self})
    .then(DiscardCount, .{})
    .repeat()
    .uponError(PeerError, .{});
```

`EchoChunk` reports `EndOfStream` at EOF; `PeerError` recovers EOF and client
I/O errors to empty success. Client's root completion unlinks the node, closes
the fd, and frees its buffer and operation. The next recv starts only after the
previous sendAll completes.

An outer `repeatUntil` drives accept. Dispatch directly connects and starts each
new Client operation, then accepting continues without waiting for that client.
All client bookkeeping runs on the reactor. `--once` stops after the first
accept but waits for that Client to retire. Allocation failure closes the new
fd; accept failure shuts down the context and drains existing clients. This
example uses neither spawn nor CountingScope.

`io.sendAll(context, fd, buffer, flags)` internally retries short writes with
`repeatUntil`. An empty buffer returns zero; a zero-byte send for a
nonempty buffer reports `WriteZero`. Cancellation and errors can occur after a
partial write, so sending is not transactional. The buffer is borrowed until
completion and no additional memory is allocated.
