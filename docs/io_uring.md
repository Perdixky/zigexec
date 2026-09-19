# io_uring Backend

**English** | [简体中文](io_uring.zh-CN.md)

`ex.IoUring.init(allocator, .{ .entries = 64 })` creates a context, ring,
eventfd, and reactor thread. The reactor performs every SQ/CQ operation;
submitters only access a lock-protected intrusive request queue. Cancellation
uses an atomic marker and eventfd. The backend requires neither `std.Io` nor
liburing and uses Zig's low-level `std.os.linux.IoUring` directly.

## API and kernel requirements

`ex.io` provides `readSome`, `writeSome`, `recv`, `send`, `openAt`,
`close`, `fsync`, `accept`, `connect`, and `sleepFor`. These senders
depend on the context protocol rather than io_uring itself.

The entry count must be a power of two of at least 2 and is subject to kernel
limits. Initialization requires `IORING_FEAT_SINGLE_MMAP` (required by Zig's
wrapper) and `IORING_FEAT_NODROP`. Deployment must permit io_uring syscalls.
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

1. On start, the sender registers a stop callback on the environment token.
2. The callback marks `cancel_requested` and writes eventfd; it never touches
   the SQ or CQ.
3. An unsubmitted request can stop immediately; an in-flight request receives
   an `ASYNC_CANCEL` submission.
4. Original and cancellation requests use separate `user_data` values, with
   the low bit identifying a cancellation CQE.
5. Once cancellation is submitted, both CQEs must arrive before the receiver is
   notified and the request storage is released.

Waiting for both completions prevents a late cancellation from referencing a
reused operation address and ensures the kernel no longer borrows the buffer.
`-ECANCELED` becomes stopped. If the original operation already succeeded,
success may still win; cancellation is neither preemption nor rollback.

The stop callback is removed before final notification, so cancellation already
running on another thread is allowed to finish. I/O completion handling retains
an execution entry, and only its exit permits `setFinished` to retire the root
connection.

## Submission pressure and wakeups

SQ capacity limits a submission batch, not the number of outstanding requests.
When the SQ fills, requests remain queued while the current batch is submitted.
The implementation neither fabricates `SubmissionQueueFull` nor waits for
pending reads before submitting later writes or cancellations.

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
completion, but does not join the worker.

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
retirement from `setFinished`, and shared-timer ownership. Restricted kernels
are not silently skipped.

`sendAll(context, fd, buffer, flags)` composes ordinary sends with
`repeatEffectUntil` to retry short writes. It returns `buffer.len`, reports
`WriteZero` when a nonempty write makes no progress, and may already have sent
partial data before an error or cancellation. It borrows the buffer until
completion. See the runnable [TCP echo example](../examples/tcp_echo.zig).
