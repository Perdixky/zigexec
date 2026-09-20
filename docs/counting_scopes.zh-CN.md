# 计数作用域与动态子任务

[English](counting_scopes.md) | **简体中文**

设计对齐当前 C++ 草案的 [counting scopes](https://eel.is/c++draft/exec.counting.scopes)
和 [spawn](https://eel.is/c++draft/exec.spawn)，将关联计数、内存分配、调度和失败策略分离。

| API | 职责 |
| --- | --- |
| `SimpleCountingScope` | 关联计数、关闭接纳、异步 join |
| `CountingScope` | 相同生命周期，加上协作式 `requestStop()` |
| `scope.getToken()` | 借用 token，包装 sender 并获取关联 |
| `ex.spawn(sender, token, env)` | 分配、启动、回收独立任务 |
| `ex.runInScope(&scope, producer)` | Zig 扩展：生产任务成功后关闭并排空，出错/停止后取消并排空 |

两个 scope 都不保存 allocator、scheduler 或任务结果，也不创建线程、自身不分配堆内存。
内部负责 operation 执行入口计数的 `Scope` 仍是独立概念。

```zig
var scope: ex.CountingScope = .{};
defer scope.deinit();

try ex.spawn(
    ex.schedule(scheduler)
        .letValue(Work, .{state})
        .uponError(HandleError, .{}), // call 返回 void，处理子任务错误
    scope.getToken(),
    .{ .allocator = allocator },
);
scope.close();
_ = try scope.join().syncWait(.{});
```

## 生命周期

- `getToken()` 返回可复制的借用句柄。`token.wrap(sender)` 不获取关联；simple scope
  原样返回 sender，counting scope 将自身 stop source 与 receiver 的取消合并。
- `token.tryAssociate()` 返回显式 `Association`；`isEngaged()` 检查是否成功，
  `take()` 转移所有权并清空原句柄。在有效 association 上调用 `tryAssociate()`
  尝试获取另一份独立关联。每个关联用 `deinit()` 释放一次。Zig 普通赋值是浅拷贝，
  **不是所有权克隆**；spawn 内部管理这些句柄。
- `close()` 只拒绝新关联，不取消既有任务。
- `requestStop()` 只请求取消，不关闭接纳；后续关联任务也会看到已请求停止的 token。
  某个子任务 stopped 不会取消同伴，也不影响接纳状态。
- 调用或 connect `join()` 不改变状态。start 后进入 joining；只要仍开放且存在关联，
  就允许继续 spawn。关联归零后永久进入 joined，拒绝新任务。
  支持多个并发 join 等待者，也可以再次 join 已 joined 的 scope。
- `deinit()` 不取消、不等待，断言 scope 处于 unused、unused-and-closed 或 joined。
  使用过的 scope 即使计数已经归零，也仍需 join。使用期间保持地址稳定，销毁前
  结束对 token、association 和作用域方法的访问。

join 期间保持开放支持递归任务：父任务持有关联，先 spawn 子任务再释放自身关联。
外部生产者需要防止 join 提前结束时，也可以在自身生命周期内持有一个关联。

## join 的调度

关联已经为空时，join 在调用线程同步成功；需要等待时，通过 receiver Env 的
`getStartScheduler()` 调度完成。join 不收集子任务结果；其 receiver 收到取消也
不会取消 scope 内的任务。排空之后，调度器仍可能报告 value、error 或 stopped。

`syncWait(.{})` 默认提供并驱动当前线程上的 RunLoop，异步 join 的后续链回到等待线程。
自定义 receiver 可以设置：

```zig
const scheduler = context.getScheduler();
const env: ex.Env = .{
    .start_scheduler = ex.StartScheduler.init(&scheduler),
};
```

`StartScheduler` 借用地址稳定的 scheduler，仅对 `submit(*ex.ScheduleTask) !void`
入口做类型擦除，不分配内存。Inline、RunLoop、ThreadPool 和 IoUring 均支持。
自定义 submitter 必须恰好执行一次已接纳任务；返回提交错误后不能再执行该任务。
scheduler 必须存活到 operation 退出。这个适配接口独立于普通泛型 `schedule()` 协议。
缺少调度器会在**排空之后**报告 `MissingStartScheduler`，不能因此遗弃子任务。
从 syncWait 提供的 Env 读取的调度器句柄不能超出该次等待的生命周期。

## spawn 的所有权与错误检查

spawn 要求空成功 tuple，并在编译期要求 `can_error = false`。
内置组合会保守推导这个属性：then 计入回调错误，letValue 计入工厂和子 sender 错误，
uponError 只有在处理函数不再抛错时才能消除上游错误；调度可以再次引入错误，
因此要在所有可能失败的阶段之后处理错误。
自定义 sender 没有元数据时视为可能失败；可以声明 `pub const can_error = false`
作为协议承诺，违反承诺将 panic。这是错误能力检查，尚不是完整 C++ completion signatures。

分配仅使用显式 `env.allocator`，不提供全局 fallback。
返回 `MissingAllocator`、`OutOfMemory` 或 `ScopeClosed` 时任务未启动，调用者仍负责
清理原本打算转交的资源；ScopeClosed 也代表达到关联数量上限。
与 C++ spawn 接纳失败时静默返回不同，Zig 显式报错，方便可靠地关闭刚接受的 socket。
为保护 allocator 自身，先获取关联再分配；分配失败也可能使 scope 变成已使用状态，仍需 join。

每个任务持有独立根 Connection，不借用调用者的 `Env.scope`。
复制 sender 不会深拷贝指针或 slice 指向的对象，不能捕获即将复用的 accept 迭代存储。
任务回收顺序是：

1. 生产者完成所有 operation 访问，再通知 receiver。
2. 完成接收函数用显式 allocator 释放 task/operation 内存。
3. 释放 association，此时才允许 join 完成。

CountingScope 还保护取消派发过程，避免同步完成的子任务在 `requestStop()` 尚未返回时
销毁 stop source。支持并发 spawn、完成与取消，但 allocator 也必须支持并发。
join 保护关联资源，不等待任意外部调用线程退出；销毁前需要协调这些调用者。

## 生产任务策略与 TCP echo

`runInScope(&scope, producer)` 是单独的单生产者生命周期组合算法，使用显式持有的
CountingScope，不是标准 scope 的成员。producer 必须以空值成功。
算法等待 producer 的 operation 退出，关闭接纳，再 join；生产任务出错/停止或
下游请求取消时，取消子任务后排空；成功则正常排空。生产任务错误会保留到清理结束。
子任务错误仍由各子链处理。使用它时让它负责 join，不要另行 join 与生产任务启动竞争。

[TCP 示例](../examples/tcp_echo.zig) 是单 reactor 的专门场景，现在手工持有
Client operation 并在 completion 回收，不再使用 spawn／CountingScope。
通用的跨线程任务组仍使用这里描述的结构化所有权 API；runInScope 的生产者失败、
取消与 join 行为继续由核心及真实 io_uring 测试覆盖。

当前实现了计数、关联与 spawn 模型；完整 async-scope API 中的
`spawnFuture` 尚未提供。


## associate：显式所有权的惰性任务

```zig
var scope: ex.CountingScope = .{};
defer scope.deinit();
var owner = ex.associate(ex.just(42), scope.getToken());
defer owner.deinit();
scope.close();
const result = try owner.takeSender().syncWait(.{});
_ = try scope.join().syncWait(.{});
```

也支持 `sender.associate(token)`。调用时立即取得关联，但不启动任务、不分配内存。
返回显式 owner，因为 Zig 没有自动析构和移动构造。

- `isEngaged()` 检查准入。拒绝时返回空 owner，其 sender 视图直接 stopped，不运行子任务。
- `sender()` 返回可组合的借用视图；start 时尝试取得独立 operation 关联。
  close 后会拒绝。原 owner 仍持有关联，等待 join 前应释放它。
- `takeSender()` 的视图在 start 时转移原有关联，因此 close 前准入的任务仍可启动。
  第一次启动清空 owner，之后再启动则 stopped。
- `take()` 显式转移 owner，清空来源。`clone()` 尝试取得另一份关联，close 后可能失败。
  不可按值复制 owner 后分别 deinit。
- `deinit()` 释放未使用的 owner。仅构造、connect 或丢弃未启动视图不会增加计数，
  也不会消耗原关联。所有借用视图开始运行前，owner 必须存活且地址稳定；
  启动后 operation 的关联独立于 owner。

这里取得/转移 operation 关联的时点是 **start**，与 C++ associate 的拥有型 sender
及 connect 时建立 operation 关联有所不同。这是针对 Zig 泛型图没有自动析构的适配，
避免未启动图泄漏计数。同一 owner 的 take、takeSender 启动和 deinit 等修改需要外部同步。

关联保留到外层图完成，包括异步下游消费期间。完成前先提取独立释放动作，
再通知根 receiver（允许回收 operation），最后释放关联。
`whenAny` 的单个分支执行退出不等于资源消费结束，因此把释放挂到外层图；
repeat 则按每轮存储复用边界释放。不能在持有关联的同一图中 join 该 counting scope，
否则会等待自身。

退休路径无需堆分配；在释放内嵌记录前，把待执行动作保存到完成线程的栈上，
栈使用量随该边界待释放的关联数增长。直接使用内部原始 connect 必须提供有效资源清理
scope，否则视图报告 `MissingExecutionScope`；通常应使用 `ex.connect` 或 `syncWait`。
