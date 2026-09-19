# Repetition

**English** | [简体中文](repeat.zh-CN.md)

## repeatEffect

```zig
const task = effect.repeatEffect();
```

The effect must complete successfully with an **empty tuple**. After every
success the algorithm reconnects and starts the same sender description.
Error and stopped terminate the repetition unchanged. `repeatEffect` itself
never succeeds, so it is normally paired with cancellation or a sentinel error
that is recovered according to application semantics.

```zig
const Tick = struct {
    count: *usize,
    pub fn call(self: @This()) void { self.count.* += 1; }
};
const task = ex.just(.{}).then(Tick, .{&count}).repeatEffect();
_ = try task.syncWait(.{ .allocator = allocator, .stop_token = source.token() });
```

This synchronous loop needs another thread to request stop. The token is checked
before each round; an asynchronous child already running still finishes through
its own cancellation protocol and is never simply discarded.

## repeatEffectUntil

```zig
const Tick = struct {
    count: *usize,
    limit: usize,
    pub fn call(self: @This()) bool {
        self.count.* += 1;
        return self.count.* == self.limit;
    }
};
const task = ex.just(.{}).then(Tick, .{ &count, 100 }).repeatEffectUntil();
_ = try task.syncWait(.{ .allocator = allocator });
```

The effect must produce exactly **one bool**: false repeats, while true
terminates with an empty successful tuple. It runs at least once unless already
cancelled. Error or stopped terminates immediately, and type mismatches receive
a dedicated compile-time diagnostic.

Both algorithms have free functions, fluent sender methods, deferred-expression
methods, and `RepeatEffect(S)` / `RepeatEffectUntil(S)` type constructors.

## State, scheduling, and lifetime

Each reconnection creates a child operation from the original sender
description, reinitializing callback captures stored by value. State that must
survive rounds belongs behind an explicit pointer or stable external owner.
Allocator and stop token are forwarded from the final receiver.

Synchronous completion is driven by a loop rather than recursive `start`
calls. Asynchronous completion transfers ownership of the drive loop through an
atomic counter. Only one child exists at a time, and its storage is reused only
after the round's completion handling exits and its child scope becomes idle.

Repetition does not change threads or insert a scheduling point. A purely
synchronous infinite effect monopolizes the current thread; include a scheduler
inside the effect when fairness is needed. A normal io_uring effect returns
execution while waiting for I/O.

## TCP echo and short writes

The [echo example](../examples/tcp_echo.zig) uses this per-connection loop:

```zig
const body = ex.upstream()
    .letValue(Receive, .{&connection})
    .letValue(EchoChunk, .{&connection})
    .then(DiscardCount, .{})
    .repeatEffect();
```

`EchoChunk` reports `EndOfStream` at EOF. The surrounding
`FinishConnection` frees the buffer, closes the descriptor, and recovers EOF
or client I/O errors to empty success. `OutOfMemory` still propagates and stops
the server, while the stopped path cleans up and remains stopped. The next
`recv` starts only after the previous `sendAll` completes.

An outer `repeatEffectUntil` drives `accept`: after one connection finishes it
accepts another, while `--once` returns true after the first. The service is
one execution graph and `main` calls `syncWait` only once.

`io.sendAll(context, fd, buffer, flags)` internally retries short writes with
`repeatEffectUntil`. An empty buffer returns zero; a zero-byte send for a
nonempty buffer reports `WriteZero`. Cancellation and errors can occur after a
partial write, so sending is not transactional. The buffer is borrowed until
completion and no additional memory is allocated.
