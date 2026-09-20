# 共享 sender 与所有权

[English](shared.md) | **简体中文**

`split(allocator, sender)` / `sender.split(allocator)` 返回 `Shared(SenderType)` owner。分配可能失败，因此返回 error union。首次订阅启动前保持惰性；上游在首次 `start` 的线程启动，所以需要其他执行位置时先组合 `startsOn`。

```zig
var shared = try work.split(allocator);
defer shared.deinit();
var another_owner = shared.clone();
defer another_owner.deinit();
const view = shared.sender();
```

## Owner 与 view

owner 是一个显式拥有引用的句柄。Zig 普通赋值没有复制构造/析构，不能把浅复制的两个 owner 分别 `deinit`；额外所有权必须使用 `clone()`。不同有效 owner 可在不同线程释放，但同一个 owner 的使用与销毁由调用方同步。

`.sender()` 只生成不拥有资源的 view，适合多次放入组合图。至少一个 owner 必须活到该 view 的 operation 开始启动；每个开始的订阅随后取得自己的引用。不启动的 operation 不持有引用，因此无需额外析构 API。

首次启动还取得单独的上游引用，保证上游操作与通知循环存在期间共享状态不被销毁。这允许：

- 订阅启动后，提前释放所有显式 owner。
- 一个根 receiver 在 completion 时销毁自身 connection。
- 完成回调中再次订阅相同 shared sender。
- 完成回调中释放最后一个显式 owner。

`deinit()` 只释放 owner，不等同于请求停止；上游可能继续运行。需要停止时用 `requestStop()` 或订阅的环境 token，再等待订阅结束。

## 缓存与通知

只有一个线程通过互斥锁把状态从“未启动”改成“已启动”。订阅节点嵌入各自 operation，通过 intrusive 链表等待；注册订阅不分配堆内存。

上游完成后，锁内发布唯一缓存，锁外通知所有订阅；后来启动的订阅直接读取缓存。value、error、stopped 都会缓存。活动订阅通常在上游完成线程收到通知，后来的订阅可以在其启动线程收到缓存；使用 `continuesOn` 显式指定下游位置。

共享上游持有自己的根 Connection，通知所有订阅后，作为完成接收函数的最后一步释放上游引用。结果保存到共享缓存，再复制到每个订阅 operation；后续节点借用订阅的结果，不依赖 shared owner 继续存活。指针/slice 仍引用原对象，不会深拷贝，也没有自动调用 `deinit` 的 RAII 行为。外部资源的生命周期仍由调用方管理。与 C++ stdexec 常用的 const-reference 共享完成形式相比，这是明确的 Zig API 取舍。

## 取消策略

任意活动订阅的 stop callback 都请求停止共享上游；`shared.requestStop()` 也请求相同 source。它不是“只取消一个订阅而让其他订阅继续”的 multicast 策略。

取消不提前分离订阅，也不释放仍被上游使用的内存。所有订阅等待唯一上游结果；若上游选择正常完成，则可能缓存/发送正常值。已缓存的完成不会被后来请求的取消改写。

请求停止时临时保留共享状态引用，防止同步完成导致上游 source 在其 `requestStop()` 返回前被销毁。

## 执行 allocator

共享上游的内部 receiver 提供 shared owner 创建时传入的 allocator。不同订阅可以有不同 allocator；共享执行不继承任一订阅的 allocator，以免上游或缓存结果依赖已结束的订阅环境。用户结果仍采用值复制且没有隐式析构，详见 [allocator 设计](allocators.zh-CN.md)。
