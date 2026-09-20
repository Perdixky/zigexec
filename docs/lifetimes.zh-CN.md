# Operation 与借用结果的生命周期

[English](lifetimes.md) | **简体中文**

## Completion 是销毁边界

每个 operation 只启动一次，并恰好调用 `setValue(*const Values)`、`setError(anyerror)`、
`setStopped()` 之一。receiver **可以在这次通知内销毁或重建 operation**，也可以继续
保留它。生产者必须先完成所有 operation 访问、注销取消回调、释放不再需要的资源，
然后发出完成通知；通知之后不能再访问 operation、嵌在其中的 receiver 或其父节点。
提前缓存指针不会延长这些对象的生命期。

`ex.connectInto(&operation, sender, receiver)`（`ex.connect` 是别名）在最终地址构造
`ex.Connection(S, R)`，已知 child 同时原地连接。连接后不能复制或移动，尚未启动也
不例外；地址保持稳定直到拥有者销毁或重建。工厂产生的 child 仍在输入可用时连接。

```zig
var operation: ex.Connection(@TypeOf(sender), @TypeOf(&receiver)) = undefined;
ex.connectInto(&operation, sender, &receiver);
operation.start(); // 同步完成也可能已经销毁 operation，不能再无条件读取它。
```

不再有 `setFinished` 通知，也不再要求生产者获取/释放 `Env.scope` 执行引用。
旧 sender 若在 completion 后继续访问自身，必须迁移；这是底层协议的破坏性变更。
普通 fluent 组合及 `syncWait`、`spawn` 的调用方式不变。

## 保留 child 就能继续借用

“允许销毁”不表示“立即销毁”。成功 tuple 必须位于 operation、自身持有的上游
operation，或拥有者明确保活的外部存储。拥有者保留存储期间，发布的 tuple 保持
有效且不可变；不能发布回调局部变量的地址。销毁/重建对应 operation 会使借用失效。
空 tuple 可使用静态空存储。

```zig
pub const Values = ex.Values(.{i64});
pub fn Operation(comptime R: type) type {
    return struct {
        receiver: ex.TypedReceiver(Values, R),
        output: Values = undefined,
        pub fn start(self: *@This()) void {
            self.output = .{42};
            self.receiver.setValue(&self.output); // 最后一次 operation 访问。
        }
    };
}
pub fn connectInto(_: @This(), out: anytype, receiver: anytype) void {
    out.* = .{ .receiver = .init(receiver) };
}
```

`letValue`/`upstream()`、`continuesOn` 和 stop 包装继续持有 child，借用结果，无需
为了新协议复制整份 tuple。`then` 仍把新结果写入自己的 output。多输入 `whenAll`
保留分支及其结果指针，最后构造一份合并 tuple；单输入直接转发。只有前后阶段要
复用同一块存储时，才必须先保存还会使用的数据；当前 let 不这样复用。

`split` 是独立所有权边界：共享缓存和每个订阅有各自的结果存储。pointer/slice
仍是浅复制，不自动拥有所指对象。`syncWait` 在完成时被唤醒，并在销毁本地
operation 之前复制返回 tuple；返回的内部 pointer/slice 不能指向即将失效的存储。

## 异步与真正的并发协调

发布给另一线程后，completion 可能早于 `start()` 返回。source 的启动路径也必须
保证发布后不再无保护地访问 operation。线程/后端的队列同步负责发布可见性；
调度器应先摘下 task 再调用它，调用后不再读取 task。I/O 后端只有在内核不再借用
buffer、取消回调已解除、目标/取消 CQE 已收齐后，才能最终通知 receiver。

不再有普遍覆盖每个异步入口的原子引用计数。`whenAll`/`whenAny` 仍以原子到达计数
保护分支启动循环及取消 dispatch；最后一个参与者完成清理再转发。共享计算仍用
引用计数保活。`withStopToken` 保留启动/完成/取消之间真正需要的协调。
这些计数不能因新的销毁规则而删除。

`repeat` 的每轮子链经过共享 TLS trampoline，在完成中清理并重连 child；终态
在清理后直接转发。重连前复制所需控制值，重连/通知后不访问旧 child。同步十万轮仍限制
栈增长；跨轮状态由外部拥有者保存。

## 关联资源的清理

`Env.scope` 现在仅指向一个资源清理记录表（兼容类型名 `Scope`），没有 active
计数、父引用、enter/leave、acquire/release 或 idle 通知。只有 `associate` 注册或摘除
记录时需要锁；普通 I/O、调度与 repeat 不为执行入口计数。

关联可以保护异步下游正在借用的资源，因此不会在关联 child 自身完成时就释放。
根完成时先摘下所有记录，将 release action 保存到栈，再通知根 receiver，最后
执行这些独立 action；不会在通知后读取已被销毁的 operation。`whenAny` 分支沿用
外层清理表；repeat 没有独立清理表，而是在存储复用边界沿具体子 operation 图清理，
由关联 child 自行摘除外层表中的记录。摘除操作与其他分支同步，栈空间随该边界的关联数增长。

在 repeat 内使用的自定义资源 operation 可实现
`pub fn cleanup(self: *@This(), continuation: anytype) void`。调用
`continuation.run()` 前必须摘除拥有的状态，且 continuation 恰好执行一次；它可能
重建或销毁 operation，返回后的释放只能使用独立局部数据。组合节点通过
`ex.cleanupOperation(&child, continuation)` 或
`ex.cleanupOperations(.{ &next, &child }, continuation)` 转发到已初始化的 child，
跳过未连接的依赖 child。已连接但启动前被取消的 child 也会被清理。该 hook 用于
存储复用，不是执行计数；生产者仍需在发送完成通知前清理执行资源。不需要复用清理
的 operation 无需实现此 hook。

`spawn` 在自身完成接收函数中释放 allocation，再释放独立的 counting-scope
association。需要回收被关联资源的调用者仍应等待该 counting scope 的 `join()`；
观察到 value 通知不等于外部关联已经释放。不能在持有某 counting-scope 关联的同一
图内 join 它，否则会等待自身。

## 编译期环境

`ex.UnstoppableEnv` 携带零大小的 `NeverStopToken`；`ex.Env` 保留动态 stop token。
内置 receiver/adaptor 用 `EnvOf(R)` 保留环境类型，不会统一擦除成 `Env`。
I/O 及订阅、join 的外层取消 callback 根据类型选择，不可取消时没有 callback
字段开销。`syncWait(.{})` 和 `spawn(..., .{ .allocator = allocator })` 自动选择
不可取消环境；显式提供 stop token 则保留取消支持。手工 receiver 可这样声明：

```zig
pub fn getEnv(_: *@This()) ex.UnstoppableEnv { return .{}; }
```

`withStopToken` 和需要取消兄弟分支的组合仍提供可取消环境。`readEnv()` 为保持
其静态 `Values` API，返回动态 `Env` 快照；显式使用旧 erased Receiver 也属于
环境类型擦除边界。自定义转发 receiver 应使用 `ex.EnvOf(R)` 作为 getEnv 返回类型，
若有意返回动态 Env，则显式调用 `.toDynamic()`。

测试覆盖 completion 内释放整个 receiver/connection、另一个线程在 start 返回前
完成、同步/异步 repeat、64 KiB 借用地址不变、关联跨异步下游保活、取消竞争和
io_uring 地址复用。主要文件为 `tests/completion_protocol.zig`、`tests/lifetime.zig`、
`tests/associate.zig`、`tests/repeat.zig`、`tests/io_uring.zig`。
