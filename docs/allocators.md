# Execution Environments and Allocators

**English** | [简体中文](allocators.zh-CN.md)

## Basis in stdexec

Reviewed on 2026-09-18 against [P2300R10](https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2024/p2300r10.html) and the current NVIDIA/stdexec implementation.

- `get_env(receiver)` obtains the environment exposed by a receiver, and
  `get_allocator(env)` queries that environment. The allocator is an
  **environment property**, not a resource-management duty of the receiver.
- P2300 section 34.5.2 defines `get_allocator(env)` as
  `env.query(get_allocator)`, with `forwarding_query(get_allocator)` equal to
  true. Wrapper nodes should therefore forward it.
- The P2300 sync-wait environment supplies scheduler queries, but neither the
  proposal nor stdexec requires every environment to contain an allocator.
- stdexec can override environment properties for a subgraph with `write_env`;
  an allocator need not always come from the outermost receiver.

## zigexec's API choice

zigexec uses a fixed `Env` structure with an optional
`?std.mem.Allocator = null`. `syncWait` still receives an environment
explicitly. A task that never queries an allocator can use
`task.syncWait(.{})`; a missing allocator is reported as
`error.MissingAllocator` only when a query is executed. No global allocator is
selected implicitly.

```zig
const env: ex.Env = .{
    .allocator = allocator,           // optional; defaults to null
    .stop_token = source.token(),      // optional; defaults to no cancellation
};
const result = try task.syncWait(env);

// Equivalent free function:
const same = try ex.syncWait(task, env);
```

There is no zero-argument `syncWait`. To select the page allocator, write
`.{ .allocator = std.heap.page_allocator }` explicitly. Supplying an
allocator does not force every node to allocate; static senders and operations
remain embedded.

## Exposing and querying the environment

A custom final receiver must provide `getEnv`:

```zig
pub fn getEnv(self: *@This()) ex.Env {
    return self.env;
}
```

Senders query the environment instead of requesting a separate receiver-owned
allocator:

```zig
const env = self.receiver.getEnv();
const allocator = env.getAllocator() catch |err| {
    return self.receiver.setError(err);
};
const bytes = allocator.alloc(u8, size) catch |err| {
    return self.receiver.setError(err);
};
```

Allocation happens after `start`; failures travel through the error channel.
`connect` remains non-allocating and infallible with respect to execution
resources. A missing `getEnv` is a compile-time error, while a missing
allocator is runtime information.

Ordinary chain nodes forward the complete environment. `whenAll` and
`withStopToken` override only the stop token and preserve the allocator.
Scheduling, transforms, all forms of `letValue`, and repetition preserve it as
well.

Application callbacks can query the allocator as a value:

```zig
const Allocate = struct {
    size: usize,
    pub fn call(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        return allocator.alloc(u8, self.size);
    }
};

const task = ex.readAllocator().then(Allocate, .{1024});
const values = (try task.syncWait(.{ .allocator = allocator })).?;
const buffer = values[0];
defer allocator.free(buffer);
```

`ex.ReadAllocator` succeeds with one `std.mem.Allocator`; if absent it sends
`error.MissingAllocator`, which can be recovered with `uponError` or
`letError`. `readEnv` returns the entire environment, whose allocator may be
null. The same sender may be connected with different environments.

## Allocation sources and resource lifetimes

`Env` borrows an allocator. It neither owns it nor acts as an arena or resource
registry. Temporary allocations belong to the operation that creates them;
owning results transferred to the final caller must be released by that caller.
Error and stopped paths must clean up as well.

`syncWait` does not create or destroy an implicit arena, because doing so could
invalidate returned pointers and slices. The allocator's backing state must
outlive the task and every outstanding result. When an entire task uses an
arena, the caller owns the arena and releases it after consuming all results.
Parallel branches require an allocator that supports their concurrent access.

`upstream` borrows completion storage internally, while callback parameters
retain their declared value types. Passing an allocated buffer as a slice copies
only its address and length. Inline arrays are copied by value and a callback
must not lend the address of a stack-local copy to asynchronous work.

## Shared execution and execution contexts

`split(allocator, sender)` creates shared state before connecting subscribers.
The shared upstream uses the owner's allocator rather than borrowing the first
subscriber's possibly short-lived environment. Subscribers may use different
allocators or an empty environment.

`ThreadPool` and `IoUring` contexts keep the allocators passed to their own
initializers. Those long-lived contexts have an ownership scope separate from
per-task execution resources.

## Migration from a required allocator

Existing calls that already pass an allocator do not change. Custom senders must
handle the error union returned by `getAllocator()`; direct access to
`env.allocator` must handle the optional. Code that only observes an
environment may leave it null.

The TCP echo example still supplies an allocator because `readAllocator`
allocates each connection's 16 KiB buffer. I/O senders that borrow caller-owned
buffers can run without a task allocator, while backend context initialization
still takes its own allocator.
