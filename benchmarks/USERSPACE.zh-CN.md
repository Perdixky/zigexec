# 手工 operation echo 的剩余用户态成本

> 历史基线：本文记录 completion 协议迁移之前的实现与测量。
> 当前实现已允许在 completion 中销毁 operation，并保留 child 来延长借用。
> 最新迁移与测量见 [completion 协议优化](COMPLETION.zh-CN.md)。

2026-09-20。针对当前手工管理 client 的版本，复用已经完成的 perf stat、
cycles:u 采样，并核对实际汇编。没有新增性能测量，也没有据此修改生产实现。

## 结论与测量边界

64 B、256 连接，每个成功校验的 echo 的计数中位数：

| 实现 | 用户态 cycles | 用户态 instructions | 内核态 cycles |
|---|---:|---:|---:|
| zigexec，手工 operation | 557.43 | 869.73 | 14332.50 |
| libxev | 154.71 | 279.52 | 14321.15 |
| zio | 670.51 | 1186.40 | 14185.55 |

相对 libxev，剩余用户态差约 403 cycles，内核态中位数差约 11 cycles。
这支持优先优化用户态，不支持把 11 cycles 当作稳定的内核差异。
相对 zio，我们的用户态已经更低。整个工作量仍主要来自内核 TCP/loopback 路径。

这些是独立计数器的中位数，并不是同一次运行的精确成本分解。内核计数包含运行
该任务期间归属的中断工作；硬件事件约 83% 时间被调度，perf 已缩放。
单独的吞吐批次中约 7% 的差距，不能仅凭这些计数完整解释；负载、批次时机与
运行波动仍需控制。假定内核和其他条件不变，即使把用户态降到 libxev 水平，
当前总 cycles 也只约减少 2.7%，不能预期吞吐提升 3.6 倍。

来源：[stat](results/2026-09-20-manual-perf.md)、
[完整记录](results/2026-09-20-manual-perf.json.gz)、
[采样源码行](results/2026-09-20-manual-zigexec-lines.txt)、
[本次核对的汇编](results/2026-09-20-manual-user-assembly.txt)。

## 1. 删除 spawn 没有删除每轮执行引用

CountingScope 管理任务集合；execution.Scope 管理 operation 何时可以安全复用或
销毁。前者已经从 echo 删除，后者还在 repeat 和 I/O source 的热路径中。

对一次 recv 收齐、一次 send 发完、没有取消和错误的稳态 echo，沿源码可以数出：

| 引用的用途 | enter/acquire + leave/release | 原子读改写次数 |
|---|---|---:|
| 外层 repeat 启动本轮 child 的保护 | 外层 iteration A | 2 |
| recv 发布至完成回调返回 | A | 2 |
| sendAll 内层 repeat 的整个运行期 | A | 2 |
| 内层 repeat 启动 child 的保护 | 内层 iteration B | 2 |
| send 发布至完成回调返回 | B | 2 |
| 合计 | | **10** |

这是正常路径的静态计数，不是插桩测量；短读、短写、错误会改变次数。根 Connection
和外层 repeat 的整个连接期引用另外计算，不是每次 echo 都获取。

`src/execution/scope.zig:49` 的 enter 是通用递归函数，先查 parent 再 fetchAdd。
汇编仍有函数调用/栈保存、parent 分支以及 `lock incq`；leave 对应原子减计数。
即便没有线程竞争，原子读改写也不等于普通计数器；把 memory order 改成 relaxed
也不会在 x86 上消除这里的 lock 指令。没有证据表明当前热点来自跨核争用。

scope.zig 的采样自耗时归因约 **39.91%**。Scope.enter 中 22.59% 的样本落在
`lock incq` 后面的栈指针调整指令上，说明必须按指令邻域理解采样，不能把每条
被采中的指令视为独立耗时原因。

这层计数有实际职责：本库允许 source 在 setValue 返回后继续访问 operation，
也允许异步下游借用上游结果。迭代重建必须等待 start 和完成回调都退出。
单 reactor 的应用事实上无需跨线程同步，但当前通用 Env/Scope 没有表达、传播
这个保证，因而仍支付通用原子协议的成本。

优化方向是明确执行域/线程亲和性，让确定在同一 reactor 执行的子树使用非原子
retirement 策略；跨线程或属性未知的子树保留原子策略。不能只根据“这次碰巧在
reactor”或“stop token 为空”就全局移除同步。

## 2. sendAll 把简单状态机展开成了完整嵌套算法

`src/io/operations/send_all.zig:41`：

```text
Just → LetValue(Next) → Then(Advance) → RepeatUntil
```

外层 echo 已经是 `Recv → LetValue(sendAll) → Then → Repeat`。所以一次普通 send
也会构建并驱动内层 repeat、维护独立 iteration scope、存储完成状态，退休后再
转发结果。上表中内层 repeat 的父引用和启动保护共 4 次原子读改写来自这层结构。

`benchmarks/libxev_echo.zig` 则让读写回调复用一个 Completion；完整写入后直接
安排下一次读，只有短写才更新剩余 slice 再写。它也有后端回调和请求准备成本，
但没有我们的这套通用嵌套生命周期驱动。

优先实现专用 SendAll operation：维护 offset、发送子 operation 和必要的退休
保护。保留短写、WriteZero、停止/错误语义。它可以减少组合层次，但实际可省多少
必须独立测量，不能直接假定上表 4 次原子操作全部消失。

## 3. trampoline 的使用边界比 stdexec 更宽

正常路径每个 echo 有三个 submit：启动 sendAll 内层 repeat、内层完成后的终态
转发、外层下一轮。通常前两个各自建立最外层 TLS 状态，外层下一轮则嵌套在
内层终态转发里运行。

`iterationFinished` 无条件 enqueue；`execute` 再判断 finish/again。因此不再
重复的成功、错误和停止路径也经过 trampoline。我们当前实现已经防止同步递归
爆栈，但仍把生命周期通知和重启调度绑在一起。

固定版本 stdexec 的 repeat_until receiver 在终态直接 cleanup 并转发完成，
重复路径才重新启动带 trampoline schedule 的子链。它并不是完全静态或完全没有
间接调用；但它没有我们额外的通用 iteration Scope 协议。

采样归因：trampoline.zig **17.76%**、repeat.zig **11.84%**。前者主要集中在
最外层 State 初始化邻域；源码第 53 行约 14.09%，汇编中 13.90% 落在常量向量
加载后的 lea 上。不能据此断言“初始化本身精确花费 14%”，也不能认定是 TLS
或 cache miss 导致。队列 drain 几乎没有样本，当前不是长队列吞吐问题。

改进方向：在满足退休条件之后直接转发终态，只让真正需要重复的路径进入
trampoline；进一步结合 completion 行为/线程亲和性减少不必要的调度入口。
仍需保证嵌套 repeat、同步失败、跨线程完成和回调自毁都安全。io_uring 的正常
完成会自然切断调用栈，但提交拒绝等路径可以同步完成，不能一律跳过 trampoline。

## 4. 重连和请求准备仍有数据搬运及分派

I/O operation 保存 Description，start 又复制到 backend Request，同时重置取消、
链表、结果等字段。外层 repeat 每轮重连 child；sendAll 内部工厂再连接 send。
后端随后检查 Description tag 并填 SQE，完成时再按请求类型解码。

当前采样 sender.zig 合计约 **6.11%**、submission.zig **4.22%**，context.zig
**13.12%**，其中 pending 队列弹出和 active 链表摘除较突出。这些是源码自耗时
归因，不能把它们全部计作“重建开销”，也不能认为 active 链表可无条件删除，
因为 shutdown 还要找到在途请求。

编译期 receiver 类型已经保留；现在的问题不能笼统归咎于 receiver 类型擦除。
重复使用 sender 以重新 connect 是 repeat 的实际需要，stdexec 也保存 child sender。
更值得减少的是稳定参数的重复写入、Request 描述副本和热路径触及的字段。
本次通用 cache-misses 事件不能证明 DRAM 带宽瓶颈；缓存布局优化需要单独验证。

## 优先顺序及验证

1. 专用 sendAll operation，作为范围最小的独立实验。
2. repeat 退休后的终态直接转发，消除无用 trampoline 入口。
3. 显式线程亲和性/执行域及非原子退休策略；这是收益潜力最大的架构改进。
4. 精简 Request 和重连时的数据写入；保持通用取消和 shutdown 正确性。

上述优先级兼顾改动范围与成本证据，不是已经测得的收益排序。每一步分别比较
每 echo 用户态 cycles/instructions，并跑原有生命周期、同步递归、跨线程、
取消 ABA、短写和 echo 测试，再独立测量吞吐。

旧 profile 的互斥锁和逐轮取消扫描热点不应继续套用到当前版本：空 stop token
已移除每 I/O 的注册锁，取消扫描只在有取消或 shutdown 时触发。当前依然有取消
标志检查和 active 链表维护，但它们不是旧版的逐轮全表扫描。
