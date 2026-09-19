# 取消协议

[English](cancellation.md) | **简体中文**

`StopSource`、`StopToken`、`StopCallback` 是独立于 `std.Io` 的取消机制。source 持有一次性停止标记与 intrusive callback 链表；token 借用 source；callback 节点由调用方提供，注册/解除注册不分配内存。

## 生命周期与线程语义

- `var source: StopSource = .{}`；开始使用后不可移动。
- `source.token()` 生成可复制的借用句柄；空 token 永远不停止。
- `var callback: StopCallback = .{}`；用 `callback.init(token, context, function)` 原地注册，注册后不可移动或复制。
- source 必须活到所有 callback `deinit()` 且所有 `requestStop()` 调用返回。token 不持有 source 的引用计数。
- `source.deinit()` 在安全构建中检查没有未解除的注册或正在执行的回调。已经触发过的注册也必须解除。
- `requestStop()` 的获胜调用者设置标记并同步调用回调；后续调用返回 `false`，不会等待首次调用完成。
- 在已经停止的 source 上注册，回调在 `init()` 返回前同步执行。注册函数的调用方必须允许这种重入。
- 解除尚未执行的注册会移除节点，避免其被调用。若别的线程已经在调用该回调，`deinit()` 等待它返回。
- 回调可解除并释放自己的节点；也可注册/解除其他节点，或再次请求停止。不要从回调销毁仍在 `requestStop()` 中的 source。
- 同一个 callback 的初始化/解除必须由其所有者串行管理；线程安全保证针对这些操作与 source dispatch 的竞争，不表示可以让两个线程同时销毁同一个节点。

回调在 source 的锁外执行，可能来自请求停止的线程，也可能来自发现 token 已停止的注册线程。回调应尽快返回，不要阻塞等待依赖自身解除注册的完成路径。不同的注册可以并发执行；不承诺回调顺序。

## 解除注册与自毁

dispatch 前在栈上创建 invocation 记录，保存执行线程 ID，并把记录地址关联到 callback。执行中自毁会标记该 invocation，dispatch 返回后不再访问已销毁节点；跨线程解除通过 condition 等待 invocation 结束。

这避免了两种常见错误：持有 source 锁调用用户回调造成重入死锁，以及从回调释放节点后 dispatcher 再次写入该节点。

## 组合算法如何转发

环境中的 token 是单个 source 的借用句柄。`withStopToken` 创建自己的 source，在新增 token 与下游 token 上注册转发回调；子 sender 接收组合后的 token。`whenAll` 也用一个内部 source，并注册下游取消的转发回调。

转发可能同步完成整个子图，进而释放父 operation。为此，转发回调在请求停止期间取得一个临时完成引用；引用降到零时先解除转发注册，再通知最终 receiver。已开始完成的 operation 不允许重新取得引用。这与 `whenAll` 启动阶段的额外引用共同保证源对象和启动循环的生命周期。

## 取消不是抢占

`just` 无条件发送值；`then` 不会中断正在执行的函数；`bulk` 与排队 schedule 有显式检查点。长 CPU 操作仍需主动检查 token。

io_uring 的取消回调只标记请求并写 eventfd。reactor 提交 `IORING_OP_ASYNC_CANCEL`，收到实际内核完成后再发送 stopped。取消与正常完成存在竞争，已经正常完成的 I/O 可以发送 value；请求停止不承诺最终一定是 stopped。
