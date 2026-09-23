# io_uring Backend

**English** | [简体中文](io_uring.zh-CN.md)

`ex.IoUring.init(allocator, .{ .entries = 64 })` creates a context, eventfd, and
reactor thread; the reactor creates the ring itself and reports setup errors
back before `init` returns. The reactor performs every SQ/CQ operation;
remote submissions use a lock-protected intrusive inbox detached in batches.
Reentrant submissions on this reactor are written straight into the SQ when it
has room and nothing is queued ahead of them; otherwise they append to a local
queue. Neither path locks or writes eventfd. Cancellation uses atomic flags and wakes only for remote calls. The backend requires neither `std.Io` nor
liburing and uses Zig's low-level `std.os.linux.IoUring` directly.

## API and kernel requirements

`ex.io` provides `readSome`, `writeSome`, `recv`, `send`, `openAt`,
`close`, `fsync`, `accept`, `connect`, and `sleepFor`. These senders
depend on the context protocol rather than io_uring itself.

The entry count must be a power of two of at least 2 and is subject to kernel
limits. Initialization requires `IORING_FEAT_SINGLE_MMAP` (required by Zig's
wrapper), `IORING_FEAT_NODROP`, and `IORING_ASYNC_CANCEL_ANY` (Linux 5.19+),
which is probed at startup; a missing feature returns `error.SystemOutdated`.
Deployment must permit io_uring syscalls.

By default the ring is created with `SINGLE_ISSUER | DEFER_TASKRUN |
COOP_TASKRUN` (Linux 6.1+). The kernel then queues completion work until the
reactor enters the ring asking for events, instead of interrupting it; every
`io_uring_enter` passes `GETEVENTS`. Kernels that reject these flags fall back
to a ring without them. `.defer_taskrun = false` opts out explicitly.
Unsupported kernels or permissions return initialization errors; there is no
implicit fallback to blocking I/O.

The backend is tested on Linux `7.2.4-arch1-2` with Zig
`0.17.0-dev.2127+e90365cd5`. Older kernels are not tested version by version;
an unavailable opcode reports through that operation's error channel.

Common parameter conventions:

- Offsets are `u64`; `io.current_offset` uses the file's current position.
- `openAt` flags are raw POSIX/Linux `u32` bits and may be constructed with
  `@bitCast(linux.O{...})`; mode contains permission bits.
- `accept` returns a new descriptor; `connect` borrows a sockaddr and length.
- `send` adds `MSG_NOSIGNAL`, turning a disconnected peer into an error
  instead of process termination.
- `sleepFor` takes relative monotonic nanoseconds; expiration is success.
- Read, write, receive, and send perform one transfer and may be short. There is
  no implicit read-exact or write-all loop.

## Completion and memory lifetime

Buffers, paths, addresses, and descriptors must remain valid until completion.
Transfers send their byte count, open and accept send a descriptor, and
value-less operations send an empty tuple. EOF is a successful zero-byte read.
Kernel errors map to Zig errors such as `BadFileDescriptor`, `FileNotFound`,
and `ConnectionReset`; an unknown errno becomes `UnexpectedIoError`.

The caller owns successfully acquired descriptors. If another `whenAll`
branch fails, a successful value can be discarded, and Zig does not run an
implicit destructor. Arrange cleanup within each branch or use an explicit
owner/defer strategy.

Each operation embeds its backend `Request`. Submission and cancellation do
not allocate request nodes in user space, though the kernel may allocate its own
resources.

## Cancellation and CQE tracking

1. On start, the sender registers a stop callback on the environment token and
   marks the request `cancellable` when that token can actually fire. Only
   cancellable requests are linked into the reactor's active list, so ordinary
   I/O never writes into neighbouring operations' cache lines.
2. The callback marks `cancel_requested`, then the context's `cancel_dirty`;
   remote calls write eventfd. It never touches the SQ or CQ.
3. An unsubmitted request can stop immediately; an in-flight request receives
   an `ASYNC_CANCEL` submission.
4. Original and cancellation requests use separate `user_data` values, with
   the low bit identifying a cancellation CQE.
5. Once cancellation is submitted, both CQEs must arrive before the receiver is
   notified and the request storage is released.

The active list is scanned only after a cancellation event. SQ
pressure preserves the dirty flag for a retry. Consuming the flag before the
scan ensures concurrent cancellations trigger this or the next scan. This is
still an O(active) scan per cancellation batch, not stdexec's individual
cancellation-task queue.

Waiting for both completions prevents a late cancellation from referencing a
reused operation address and ensures the kernel no longer borrows the buffer.
`-ECANCELED` becomes stopped. If the original operation already succeeded,
success may still win; cancellation is neither preemption nor rollback.

The stop callback is removed before final notification, so cancellation already
running on another thread is allowed to finish. The final notification may destroy
the root connection. No request, receiver, or operation access follows it.

## Submission pressure and wakeups

SQ capacity limits a submission batch, not the number of outstanding requests.
When the SQ fills, requests remain queued while the current batch is submitted.
The implementation neither fabricates `SubmissionQueueFull` nor waits for
pending reads before submitting later writes or cancellations.

Local scheduler tasks also execute in batches; reentrant jobs wait for the next
iteration. Remote submission and shutdown share an admission lock, so accepted
inbox entries cannot be lost during shutdown.

The eventfd poll is always preserved or rebuilt first so cross-thread wakeups
remain possible under pressure. The reactor continues nonblocking submissions
while user requests or pending cancellations remain, and waits for a CQE only
when there is no such work.

`NODROP` lets the kernel retain overflow completions when the CQ is full. The
reactor consumes the CQ and flushes overflow. Cancellation submissions take
priority over new I/O, but there is no fairness or bounded queue-length
guarantee; request nodes belong to caller operations.

## Shutdown and errors

`shutdown()` may be called from any thread, including a reactor callback. It
rejects new submissions, cancels queued and in-flight work, and waits for real
completion, but does not join the worker. Queued requests complete as stopped;
in-flight requests, cancellable or not, are cancelled by one
`ASYNC_CANCEL_ANY | ASYNC_CANCEL_ALL` submission. Nothing is submitted after
shutdown is observed, so that single cancellation reaches every request.

`deinit()` calls shutdown, joins the worker, destroys the ring, and closes
eventfd. It must not run on the reactor thread. The context must outlive every
concurrent submit, cancel, or shutdown call. Kernel work that cannot be
interrupted may extend shutdown indefinitely; no fixed cancellation latency is
promised.

New requests after shutdown receive `error.ContextClosed`. Ordinary operation
failures use the sender error channel. Interrupted `io_uring_enter` calls and
temporary resource pressure are retried. Irrecoverable ring infrastructure
damage panics rather than pretending completion and releasing memory the kernel
might still use.

Continuations run on the reactor thread by default. Do not block that thread in
`syncWait` on the same context; move expensive work with
`continuesOn(cpu_scheduler)`.

## Tests and complete sends

`zig build test-io` runs real-kernel tests for file content and EOF, kernel
errors, timers, socket pairs, loopback connect/accept, in-flight and shutdown
cancellation, 128 queued reads on a two-entry ring, address reuse, connection
retirement from completion, and shared-timer ownership. Restricted kernels
are not silently skipped.

`sendAll(context, fd, buffer, flags)` issues ordinary sends and retries short
writes, resuming through the trampoline between sends. It returns `buffer.len`, reports
`WriteZero` when a nonempty write makes no progress, and may already have sent
partial data before an error or cancellation. It borrows the buffer until
completion. See the runnable [TCP echo example](../examples/tcp_echo.zig).

The echo server uses one accept loop. Dispatch manually connects and starts
client operations on the reactor. Each Client owns a buffer and Connection;
an intrusive list tracks live clients, and completion unlinks, closes the fd,
and frees storage. This single-reactor example needs no spawn, CountingScope,
or per-client stop source. The completion protocol permits immediate operation reclamation without
generic execution counts. `--once` drains its one client. Accept failure shuts down
the context and drains actual I/O completions. Tests include allocation-failure
fd cleanup, accept-failure drain, and 32 simultaneous clients plus an idle client.
