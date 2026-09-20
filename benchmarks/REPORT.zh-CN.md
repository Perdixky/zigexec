# 2026-09-19：优化前 zigexec、libxev、zio TCP echo 测量与问题分析

优化完成后的完整测量与结论见 [最终性能报告](PERFORMANCE.zh-CN.md)。

本文记录优化前提交 `7da66f5` 的测量与归因；文中的“当前实现”均指该提交。
后续原地构造、具体 receiver 与本线程唤醒优化见 [优化报告](OPTIMIZATION.zh-CN.md)。

该版本的本机测量不支持“zigexec 比 libxev/zio 更快”。单连接的吞吐接近且波动区间
重叠；多连接场景，zigexec 的吞吐落后，同时完成每次 echo 的 CPU 成本更高。
这并不证明 sender/receiver 模型天然慢：后端的本线程提交路径、取消扫描、
组合 operation 的状态布局，都是当前实现中可以单独检查的问题。

## 版本与环境

| 项目 | 固定版本 | 编译器 |
|---|---|---|
| zigexec | `7da66f5acb89794366734bf25188a932030e6363`，库源码未修改 | `0.17.0-dev.2127+e90365cd5` |
| libxev | `9ce8e8e6ff89e583258a7f8e7adeeeaeae8611bf` | `0.16.0` |
| lalinsky/zio | `b3475afacc7674f01842a9b1e7499f0976972f22`，官方 zig-0.17 分支 | `0.17.0-dev.2127+e90365cd5` |

AMD Ryzen 5 7500F，6 核 12 线程，Linux `7.2.4-arch1-2`，CPU governor 为
`powersave`，保留正常调频。这是正在运行桌面程序的开发机，不是隔离实验室环境。
服务端绑 CPU 1，客户端绑 CPU 2/3/4/5，均为不同物理核。三者使用 LLVM、
ReleaseFast、本机 CPU 优化和 io_uring；每个服务端只有一个处理 I/O 的执行线程。
每场景预热 1 秒、测量 3 秒、5 轮，共 90 次，交错顺序。

三者应用层行为一致，但编译器版本和运行时配置不完全相同：zigexec/libxev 的
SQ entries 为 64，zio Runtime 默认 256；zio 的 runtime API 未暴露 ring 大小。
不能把这个结果当成排除了所有混杂因素的抽象模型比较。

## 主结果

以下为完整、逐字节校验通过的 echo/s 中位数；一个 echo 包含一次请求和完整响应。

| 消息 | 连接数 | zigexec | libxev | zio | zigexec 相对 libxev / zio |
|---|---:|---:|---:|---:|---:|
| 64 B | 1 | 94,999 | 100,700 | 95,184 | −5.7% / −0.2% |
| 64 B | 32 | 317,495 | 381,027 | 345,475 | −16.7% / −8.1% |
| 64 B | 256 | 287,169 | 351,442 | 340,163 | −18.3% / −15.6% |
| 4 KiB | 1 | 85,695 | 88,423 | 88,639 | −3.1% / −3.3% |
| 4 KiB | 32 | 268,931 | 321,873 | 291,197 | −16.4% / −7.6% |
| 16 KiB | 32 | 222,257 | 257,210 | 238,401 | −13.6% / −6.8% |

单连接结果不宜过度解读。例如 zigexec 的 64 B 单连接吞吐在 89,584–103,399
之间波动，范围覆盖竞争实现。32 连接时差异更稳定：zigexec 为
316,467–323,132，libxev 为 378,108–383,456，zio 为 343,704–360,726。

64 B、32 连接时，服务端 CPU 时间分别约为 **2.16 / 1.64 / 1.91 µs/echo**，
p99 RTT 为 **131 / 112 / 123 µs**（顺序为 zigexec/libxev/zio）。zigexec 不只
吞吐较低，每份相同应用工作也消耗更多 CPU。所有试验中单个负载进程的 CPU
使用率最高约 50.7%，未观察到客户端核心占满，但这不消除整个负载生成机制的影响。

## 为什么“编译期组合”还会有开销

编译期确定图结构能够省掉通用调度器、协程栈和逐节点堆分配；这部分设计有
性能潜力。但编译期类型并不自动删除运行时协议成本。当前实现还有：

1. **reactor 给自己写 eventfd。**
   [`Context.submit`](../src/backends/io_uring/context.zig) 无论调用线程是谁，都
   加锁入队并调用 `wake()`，后者执行 `write(eventfd)`。echo 的 recv 完成回调在
   reactor 线程上，提交 send 时仍走此路径；send 完成后的下一次 recv 也是如此。
   常见无短读/短写的一轮 echo 就有两次这类写入，随后还有 wake poll CQE、读
   eventfd 和重新布置 poll 的处理。跨线程发布需要唤醒；本线程串联也支付同样
   成本，是这套实现目前缺少局部快速路径的具体表现。

2. **没有取消也扫描全部在途请求。**
   [`Context.run`](../src/backends/io_uring/context.zig) 每个 reactor 周期都遍历
   `self.active`，逐个检查取消标志。单轮成本是 O(active requests)，并发高时
   对不发生取消的正常请求同样付费。它不是“每次 echo 都 O(N)”的简单等式，
   因为多个 CQE 可以被批量处理；实际成本取决于批次大小和 active 数量。

3. **完成与复用协议包含真实的原子操作。**
   [`Scope.enter/leave`](../src/execution/scope.zig) 会递归更新父 scope 的原子
   计数；当时的 `repeatEffect` 实现（现为 [`repeat`](../src/algorithms/repeat.zig)）使用原子 drain
   所有权，并等旧操作退役后重新 connect。这些机制保障取消、内联完成、跨线程
   完成和回收的正确性。不能在没有等价生命周期证明时直接删除。
   [`sendAll`](../src/io/operations/send_all.zig) 内部本身还是一个
   `just → letValue → then → repeatEffectUntil` 组合，再嵌入外层 echo repeat。
   因此“没有协程切换”不等于“没有其他状态机和同步开销”。这一项尚未单独量化。

4. **receiver 仍存在类型擦除边界。**
   [`Receiver`](../src/execution/receiver.zig) 保存 `context` 和多个函数指针。
   编译器可能消除部分间接调用，但跨异步完成边界不能先验假定它会把整个图完全
   内联。实验没有单独量化动态分派的成本；不过，使用具体 receiver 类型的价值
   不限于去掉间接调用，它也支持下面所述的 operation 构造方式。

## 内存布局：已经直接确认的另一项问题

64 B、256 连接时，三者进程 RSS 中位数约为 **23.0 / 1.6 / 5.4 MiB**。
RSS 会受到页面实际触碰情况影响，因此另外用真实 echo 类型做了 `@sizeOf` 探针：

| 阶段 | sender 字节数 | operation 字节数 |
|---|---:|---:|
| `schedule.letValue(Echo)` | 16,448 | 19,072 |
| 再接 `then(Close)` | 16,456 | 35,632 |
| 再接 `uponError(CloseError)` | 16,464 | 52,200 |
| 再接 `letStopped(CloseStopped)` | 16,472 | 68,888 |
| scope stop-token wrapper | 16,480 | 85,656 |

最外层 `Connection` 为 **102,304 字节**；`spawn` 私有节点的同字段布局为
**102,392 字节，约 100 KiB/连接**。原始 Echo factory 只有 16,400 字节，其中
16 KiB 是收发缓冲区。外层每添一个组合节点，operation 又增加约 16 KiB。

原因是多个 operation 同时保存完整的 `sender` 和 `child: S.Operation`；sender
递归携带内嵌 16 KiB 数组的 Echo factory。最外层 `Connection` 又保留 sender
和完整 child。这是**同一个大 capture 在类型布局中重复占位**，不是每条请求都
新分配 100 KiB，也不是观察到每次 echo 都 memcpy 100 KiB。不要混淆这几件事。

根本的改进方向是调整 connect/receiver 协议，让 sender 描述在连接时转化为
operation 状态，而不是在每层 operation 中继续保留完整上游 sender。以 `then`
为例，具体 receiver 适配器可按值保存 callback、下游 receiver 和必要结果存储；
connect 把这个适配器交给上游，外层 operation 只保存构造完成的 child operation。
这样 callback 和下游状态随 child 一起存在，不需要把外层 operation 自身包装成
一个类型擦除 receiver，再等到 start 时连接 child。

三个问题需要区分：

- `sender: S` 与 `child: S.Operation` 同时逐层保存，是大 capture 重复占位的直接原因。
- 当前 `connect` 的参数名虽是 receiver，实际却经常传入 `Receiver.init(self)`，
  使父 operation 兼任 receiver。项目选择在 start 才建立这些内部地址关系，并
  保留 sender 用于稍后连接；这不是父状态指针必然造成的结果。P2300 的构造期
  原地连接同样可以传递父状态指针。按值 receiver 则是线性适配器的另一种实现。
- 将默认协议改为 `Operation(R)`，保留 receiver 的具体类型，可以直接表达上述
  静态组合。仅去掉类型擦除而继续保存完整 sender，并不会自动消除 16 KiB 副本。

“只存 child”针对不需要额外执行状态的适配器，不是所有 operation 的字面约束。
叶子 I/O 仍需 fd/buffer/request，`letValue` 需工厂及后续 operation，`repeat` 需
用于重新连接的描述或工厂；`whenAll` 等还需要共享完成状态。它们应各保存一份
必要状态。receiver 可以引用稳定的父状态；是否回指父 operation 本身不是冗余
存储的判据，稳定地址和类型依赖需要明确设计。
确实需要内部地址的操作可考虑原地初始化；返回 operation 值时仍不能携带指向
临时局部对象的指针。尤其 Echo 的 factory 地址和借用结果必须保持有效。

这些是协议重构的目标，尚未实现或测量其收益。把缓冲区单独堆分配可用于对照，
但不能替代 operation 构造与布局的修正。

P2300 的规范、stdexec 的构造代码以及 C++ 原地构造实验见
[P2300 operation 研究](../docs/p2300-operation-state.zh-CN.md)。其中纠正了先前
将“父指针必然要求延迟 connect”作为一般原因的分析。

布局探针与输出见 [`layout.py`](layout.py) 和 [记录](results/2026-09-19-layout.txt)。

## 隔离改动后重测：主要吞吐损耗来自哪里

另外做了 105 次试验：64 B、1/32/256 连接，预热 0.5 秒、测量 2 秒、每项 5 次。
原版、四个实验变体、libxev、zio 每轮交错重测。各个变体只在缓存目录里修改源码，
每个变体在测量前都通过现有核心测试、真实 io_uring 测试和共同 TCP 检查。
这里的基线来自这批试验，不能把不同时段的主比较数据和实验数据拼成百分比。

| 变体 | 32 连接 echo/s | 相对原版 | CPU µs/echo | 256 连接 echo/s | 相对原版 | CPU µs/echo |
|---|---:|---:|---:|---:|---:|---:|
| 原版 zigexec | 319,368 | — | 2.156 | 283,611 | — | 2.462 |
| 仅取消本线程提交的 eventfd 自唤醒 | 363,064 | +13.7% | 1.777 | 307,525 | +8.4% | 2.122 |
| 仅按需扫描取消 | 317,396 | −0.6% | 2.159 | 286,478 | +1.0% | 2.434 |
| 前两项叠加 | 362,422 | +13.5% | 1.780 | 317,526 | +12.0% | 2.053 |
| 仅 SQ entries 64 → 256 | 320,540 | +0.4% | 2.153 | 302,520 | +6.7% | 2.227 |
| 同批 libxev | 383,936 | — | 1.628 | 347,460 | — | 1.874 |
| 同批 zio | 349,955 | — | 1.886 | 339,703 | — | 1.924 |

**自唤醒是实测支持的首要优化点。** 保留互斥锁、队列、所有 sender/receiver
组合与生命周期逻辑，仅使 `submit` 在当前 reactor 线程上不调用 `wake()`，
32 连接吞吐提升 13.7%，CPU/echo 降低约 17.6%。单连接的 CPU/echo 也从
6.401 降到 4.833 µs（约 −24.5%）。32 连接时这个变体已经超过同批 zio 的
吞吐中位数，但仍比 libxev 低约 5.4%；256 连接仍低于两者，不能宣称全面领先。
收益包含省去 eventfd 写入及其后续 CQE/读/rearm 工作，不是对单个 syscall
耗时的直接测量。

**取消扫描不是这组负载中已证实的大瓶颈。** 单独变体只有 −0.6%～+1.0%
变化；32 连接叠加也没有超过只改自唤醒。按需扫描引入了一个每轮 atomic swap，
高并发或取消密集负载可能有其他权衡，不能从 O(N) 的源码形状推断主要耗时。
256 连接叠加的中位数有额外收益，但轮间波动重叠，不能把这个增量做精确归因。

**ring 大小是实际混杂因素。** 32 连接时基本无变化，256 连接时提升 6.7%。
所以主比较的高并发差距不能全部记在 sender/receiver 头上。即便把 zigexec
调到与 zio 相同的 256 entries，当前单项实验也尚未追平竞争实现。多项调整
的收益不能直接相加；本次没有测“全部改动再叠加 ring256”。

这是一组有控制变量的应用级实验，不是采样 profiler 的函数耗时占比；它支持
上述快速路径判断，但没有量化剩余互斥锁、scope 原子计数和间接调用各占多少。
数据及实验变体完整源码见 [对照表](results/2026-09-19-diagnosis.md) 和
[原始数据](results/2026-09-19-diagnosis.json.gz)，复现脚本为 [`diagnose.py`](diagnose.py)。

## 建议的改进顺序

1. **补 reactor 本线程提交快速路径。** 先采用已测有效的自唤醒抑制；外部线程
   的提交、取消和 shutdown 保留可靠的 wake 协议。实验只针对请求 `submit`，
   没有无差别删掉 `submitTask`/取消的唤醒。后续再单独测本地队列和批量摘队，
   避免无竞争时仍为每个请求 lock/unlock。不要一次混入所有优化。
2. **解决重复保存大 capture 的 operation 布局。** 这是直接确认的内存问题。
   以具体 receiver 类型、`Operation(R)`、connect 阶段构造 child 为协议目标，
   去掉普通组合节点冗余的上游 sender；再明确 factory、buffer、共享状态的唯一
   存储和借用关系。减少内存布局尚未做吞吐归因。
3. **让 ring 容量可按负载调节，并继续比较。** 高并发单项调优有收益，但不是
   一劳永逸的更大更好，也不替代后端快速路径。
4. **随后剖析剩余成本。** 对 `sendAll` 的通用 repeat 状态机、scope 层级和
   receiver 间接调用分别设计语义等价实验。取消扫描在本轮证据下优先级较低。

实验变体尚未合入正式库；现有测试通过不足以覆盖所有取消/关闭/提交交错。
这里的判断是：**sender/receiver 具有性能潜力，当前实现距离低开销还有明确的
工程工作；首轮性能差距不足以判定架构失败，也不足以保证优化后必然领先。**

## 验证与复现

原库的 `zig build test-all -Doptimize=ReleaseFast` 和 `test-echo` 通过。
三库适配器都通过相同的二进制分片、EOF/半关闭、32 并发加 idle、reset/reconnect
验证；原生负载器另有分片回包和故意损坏回包的端到端检查。

[方法、限制及运行命令](README.md)；[完整统计表](results/2026-09-19-ryzen7500f.md)；
[90 次原始测量](results/2026-09-19-ryzen7500f.json.gz)。原始 JSON 无损 gzip 压缩存档。
这是单机 closed-loop TCP
测试，不代表文件 I/O、timer、跨线程调度、取消密集场景或多核扩展性能。
