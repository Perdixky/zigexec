# Shared Senders and Ownership

**English** | [简体中文](shared.zh-CN.md)

`split(allocator, sender)` and `sender.split(allocator)` return a
`Shared(SenderType)` owner. Allocation can fail. The upstream remains lazy
until the first subscription and starts on the thread calling the first
`start`; compose `startsOn` first when another execution location is needed.

```zig
var shared = try work.split(allocator);
defer shared.deinit();
var another_owner = shared.clone();
defer another_owner.deinit();
const view = shared.sender();
```

## Owners and views

An owner is an explicitly owning reference. Ordinary Zig assignment has no copy
constructor, so two shallow copies must not both call `deinit`; use `clone()`
to acquire another reference. Separate valid owners may be released on separate
threads, but access to one owner must be synchronized by its caller.

`.sender()` creates a non-owning view suitable for repeated composition. At
least one owner must survive until the view's operation starts. A started
subscription then acquires its own reference; an operation that never starts
does not need a destructor.

The first start also acquires a distinct upstream reference. This permits all
explicit owners to be released after subscription, a root receiver to destroy
its connection in `setFinished`, re-subscription from completion callbacks,
and release of the final owner from a completion callback.

`deinit()` only releases ownership; it does not request cancellation. Use
`requestStop()` or a subscriber environment token and then wait for completion
when shutdown is required.

## Caching and notification

Exactly one thread changes the state from not-started to started under a mutex.
Subscription nodes are embedded in their operations and wait in an intrusive
list, so registering a subscription does not allocate.

The upstream publishes one cached value, error, or stopped result under the
lock, then notifies subscribers outside it. Late subscribers read the cache
directly. Active subscribers are normally notified on the upstream completion
thread; late ones may complete on their starting thread. Use `continuesOn` to
choose an explicit downstream location.

The shared upstream owns a root `Connection` and releases its execution
reference only after all execution entries exit. Its result is cached, then
copied into each subscription operation. Downstream nodes borrow that
subscription-local result and do not depend on the owner remaining alive.
Pointers and slices are still shallow copies; external resources remain
caller-managed. This is an intentional Zig API choice rather than stdexec's
common const-reference shared-completion form.

## Cancellation policy

The stop callback of any active subscriber requests cancellation of the shared
upstream. `shared.requestStop()` targets the same source. This is not a
multicast policy where one subscriber can detach while all others continue.

Cancellation does not detach subscriptions early or release memory still used
by the upstream. All subscribers wait for the single result. If the upstream
wins the race with normal completion, that value may still be cached and sent;
a later cancellation request does not rewrite a cached completion.

Requesting stop temporarily retains the shared state so synchronous completion
cannot destroy the upstream source before `requestStop()` returns.

## Execution allocator

The shared upstream receiver uses the allocator passed when the owner was
created. Subscriber environments may use different allocators. Shared execution
does not inherit a subscriber allocator, avoiding dependencies on a short-lived
subscriber arena. Results use value copies without implicit destruction. See
[execution environments and allocators](allocators.md).
