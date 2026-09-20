# 对照 stdexec 的第二轮优化

> 历史基线：本文记录 completion 协议迁移之前的实现与测量。
> 当前实现已允许在 completion 中销毁 operation，并保留 child 来延长借用。
> 最新迁移与测量见 [completion 协议优化](COMPLETION.zh-CN.md)。

研究版本固定为 NVIDIA/stdexec `957a8331d992cb81dd00091aa5f9a9f2a60ec978`。
这轮在具体 receiver／原地 connect 改造之上继续优化，不把之前已经取得的收益
重复算进来。对照二进制是本轮修改前的工作区版本，不是最初的 git HEAD。

## 源码对照与实际取舍

| stdexec 实现 | 观察 | zigexec 的处理 |
|---|---|---|
| [repeat_until.hpp](https://github.com/NVIDIA/stdexec/blob/957a8331d992cb81dd00091aa5f9a9f2a60ec978/include/exec/repeat_until.hpp) | `repeat` 转为带永假条件的 `repeat_until`，子链经 trampoline 调度；旧 effect 名称是弃用别名 | 公开命名改为 `repeat`、`repeatUntil` 和对应类型构造器；保留旧别名；两个算法直接共用 Repeat(S, until) 实现 |
| [trampoline_scheduler.hpp](https://github.com/NVIDIA/stdexec/blob/957a8331d992cb81dd00091aa5f9a9f2a60ec978/include/exec/trampoline_scheduler.hpp) | TLS 保存当前调度状态，异构 operation 共用 intrusive 队列；限制递归深度及栈距离 | 新增公开 `TrampolineScheduler`，默认深度 16、栈距离 4096；超限进入 FIFO，移出节点后才执行，不在回调后解引用可能已释放的节点 |
| [io_uring_context.hpp](https://github.com/NVIDIA/stdexec/blob/957a8331d992cb81dd00091aa5f9a9f2a60ec978/include/exec/linux/io_uring_context.hpp) | 批量摘取提交队列；取消请求通过独立任务提交；目标和取消完成共同决定释放 | reactor 本地无队列锁；跨线程 inbox 批量摘取；有取消事件才扫描 active，SQ 满重试；仍等待目标与取消两个 CQE |
| [atomic_intrusive_queue.hpp](https://github.com/NVIDIA/stdexec/blob/957a8331d992cb81dd00091aa5f9a9f2a60ec978/include/exec/detail/atomic_intrusive_queue.hpp) | 原子入队，批量取出并反转；仍需处理关闭期间提交者的生命期 | 本轮保留跨线程 inbox 的 admission 锁，避免把数据结构换成 CAS 队列后漏掉 shutdown 与已接受任务之间的同步 |
| [__when_all.hpp](https://github.com/NVIDIA/stdexec/blob/957a8331d992cb81dd00091aa5f9a9f2a60ec978/include/stdexec/__detail/__when_all.hpp) | 零输入为 just，单输入直接返回 child；多分支使用原子到达计数，并按 completion traits 决定是否需要 stop source | 零／单输入不再生成 fan-in 状态、stop source 或结果副本；多分支保留计数与取消。当前只有 can_error，不足以证明 sender 不发 stopped，不能据此删除多分支 stop source |
| [__then.hpp](https://github.com/NVIDIA/stdexec/blob/957a8331d992cb81dd00091aa5f9a9f2a60ec978/include/stdexec/__detail/__then.hpp) | 具体 callback 与 receiver 状态，完成时静态分发 | 第一轮已采用；普通 transform 不引入执行计数，不再次添加包装 |
| [__let.hpp](https://github.com/NVIDIA/stdexec/blob/957a8331d992cb81dd00091aa5f9a9f2a60ec978/include/stdexec/__detail/__let.hpp) | 可以销毁 upstream 后在 variant 存储中构造依赖操作 | 本项目 let/upstream 允许借用上游 tuple，生产者还可在 completion 返回后访问自己；继续共存两份不同阶段的 operation，不能覆盖旧存储 |
| [__starts_on.hpp](https://github.com/NVIDIA/stdexec/blob/957a8331d992cb81dd00091aa5f9a9f2a60ec978/include/stdexec/__detail/__starts_on.hpp) | 专用调度节点及执行环境传播 | 第一轮已用专用节点提前连接 child；本轮可用 trampoline scheduler。完整 domain／completion scheduler 查询系统仍未实现 |
| [__continues_on.hpp](https://github.com/NVIDIA/stdexec/blob/957a8331d992cb81dd00091aa5f9a9f2a60ec978/include/stdexec/__detail/__continues_on.hpp)、[__bulk.hpp](https://github.com/NVIDIA/stdexec/blob/957a8331d992cb81dd00091aa5f9a9f2a60ec978/include/stdexec/__detail/__bulk.hpp) | 调度转交保存完成状态；bulk 按 execution policy/domain 选择实现 | 现有 continuesOn 保留借用结果和具体调度 operation；bulk 仍明确为顺序执行。没有凭名称加入不兼容的并行语义 |

stdexec 也不是“所有内部边界都无动态分发”：该版本 repeat 的基础状态带虚函数，
trampoline 队列和 io_uring task 使用运行时函数入口，跨线程队列及生命周期也使用
原子操作。这里借鉴的是状态边界、批次和只为需要的能力付费，而不是逐行翻译。

## repeat 的生命周期证明

旧 repeat 已有防递归的原子 drain loop，并非每次完成都无界递归；问题是驱动计数
与父 scope 计数在热路径叠加。新实现把职责分开：

1. `connectInto` 仍在最终地址构造第一轮 child，地址稳定不依赖推迟到 start。
2. `start` 只向父 scope 获取一次执行引用，覆盖整个 repeat 以及排队中的 trampoline task。
3. 每次启动前进入独立 iteration scope，child 发布异步任务也获取该 scope 的引用。
   iteration 不再把每次增减传播给父 scope。
4. child 的逻辑完成只记录 action。`child.start()` 返回后执行一次尾部 leave；
   所有异步生产者也在最后一次访问 operation 后 leave。
5. iteration 归零才调度下一轮。尾部 leave 之后不再访问 child、task 或 repeat 状态，
   因而下一轮在其他线程重建也安全。TLS 只限制递归，跨线程同步仍由 scope 原子计数承担。
6. 最终 action 在所有 child 入口退出后向下游发送，再释放整个 repeat 持有的父引用；
   根接收者可以在 setFinished 释放 operation。

因此没有取消必要的退休检查，也没有为防递归而为每轮分配堆节点。repeat 为重连
保留 sender 描述仍属必要状态，不能像一次性 transform 一样删除。

## io_uring 与之前 perf 热点的对应关系

上一轮用户态采样中 scope 约 25.5%、mutex 原子操作约 22.1%、取消扫描附近约 18.7%、
repeat 驱动约 13.2%。这些是采样归属，不是四个能简单相加的独立性能上限。

- **scope：** repeat 改为整个运行期间保留一个父引用，避免每次 I/O／每次迭代沿
  嵌套 scope 链逐级计数。第一批测量的 echo 仍使用 spawn/CountingScope；随后按用户要求移除了该示例的
  通用任务管理，单独做第二批对照。
- **mutex：** 先前每次 I/O 的 callback 注册、提交、取出、注销约四组 lock/unlock。
  reactor 本地提交和取出现在各去掉一组；跨线程提交仍加锁，但消费按批次摘取。
  stop callback 的两组锁仍保留，因为允许别的线程同时 requestStop。无 futex
  syscall 不等于没有成本：不竞争的 CAS/exchange 仍是带同步语义的原子指令。
- **取消：** 旧实现在没有取消时也遍历所有 active 请求并检查标记。新实现普通
  循环只读 context 标记；取消事件才触发扫描，SQ 满保留重试信号。标志发布在
  request 标记之后，消费发生在扫描之前，不丢失与扫描并发的取消。
- **repeat：** 去掉每实例 work 原子驱动计数，改为共享 TLS trampoline，收益还包括
  sendAll 内嵌 repeat；iteration 自身的跨线程生命周期计数仍然存在。

取消扫描目前仍为 O(active)，只是移出了无取消的稳态路径。进一步变成 stdexec
那样的 O(cancelled) 任务队列，需要对排队取消节点增加存活协议：不能把 request
指针直接塞入队列后，又允许正常 CQE 释放它。当前实现不冒这个 ABA 风险。

本地普通调度任务也不再自唤醒，但仍在下一批执行；hasQueued 包含这些任务，
避免没有 I/O 时阻塞睡眠。跨线程 submit 与 shutdown 共用 admission 锁；观察到
关闭后再摘取 inbox，关闭前已接受的请求和任务不会丢失。未改 SQ64、ring flags
或内核配置。

## 验证

- Debug：`zig build test-all`，174/174 运行测试和编译失败诊断通过。
- ReleaseFast：`zig build test-all test-echo -Doptimize=ReleaseFast`，174/174、诊断与 TCP 测试通过。
- `zig build -Doptimize=ReleaseFast`：全部示例通过。
- 新增 trampoline 的多线程独立队列、异构回调、FIFO、节点执行中自毁、深度／栈阈值和取消测试。
- 新增嵌套 repeat 十万次迭代、旧 API 别名、单输入 whenAll 的各完成通道与 token 传递测试。
- 新增两条目 ring 下 128 个本地 timer 的取消压力、1 万次本地调度重入测试。
- 原有完成后访问旧 operation、跨线程 repeat、异步 setFinished 自毁、双 CQE、100 次地址复用、shutdown 已接受工作等测试继续通过。
- `python3 benchmarks/test_load.py`：两个负载生成器测试通过。

只改库时，Echo operation 布局由 18,032 增至 18,048 字节（两个 repeat 各多 8 字节）：
trampoline Task 的两个机器字替换原先一个 work 计数。这里以很小的存储增量减少
同步与调度成本，没有把布局缩小当成唯一指标。

## 测量方法

与第一轮相同：Ryzen 5 7500F，server CPU1，client CPU2/3/4/5，ReleaseFast + LLVM + native。
libxev/zio 使用之前锁定的源码和编译器；libxev Zig0.16，另两者 Zig0.17；zio SQ256，
其他 SQ64。正式测量前四个二进制都通过分片、半关闭、并发、reset/reconnect 校验；
测量期间响应逐字节校验。

对照来自 `.bench-cache/before-stdexec-round/zigexec-echo`，build.json 记录其原始完整
manifest，并校验二进制 SHA-256。新 manifest 还记录新增源码内容，避免仅有 git diff
而遗漏未跟踪的 trampoline 和 repeat 文件。

```sh
python3 benchmarks/build.py --baseline-snapshot .bench-cache/before-stdexec-round
python3 benchmarks/run.py --libraries baseline,zigexec,libxev,zio \
  --output benchmarks/results/2026-09-20-stdexec-round.json
```

六个场景，每场景预热 1 秒、测量 3 秒、5 轮，四个实现随机交错，合计 120 次。


## 单 reactor 示例改为手工 operation 所有权

`examples/tcp_echo.zig` 现在使用普通 Client 链表，所有链表操作和 client.start
只在 reactor 发生。Dispatch 在 accept 回调直接分配 Client，把 echo buffer 和
Connection 放到最终地址后 connect/start。不再使用 spawn、CountingScope、
runInScope、每连接 stop source 或额外的 schedule/letValue 跳转。

Client 的 setValue/error/stopped 不回收存储；setFinished 才摘链、close fd、destroy。
启动可能同步失败并回收 client，所以 Dispatch 在 start 后不再读 client。
第一条 accept 的 start 也通过一次 launch task 投递到 reactor，避免首次启动与
完成的竞争把 bookkeeping 转移到 main。main 的 RunLoop 只接收最终排空通知。

`--once` 停止继续 accept，但等现有 Client 真正退休。accept 或分配出错时关闭
server 专用 context，让在途请求正常走取消及双 CQE 排空，再返回原始错误。
分配 Client 失败时还没有转移 fd 所有权，errdefer 负责 close。

这进一步去掉了 echo 每次 I/O 的 stop callback 注册/注销锁：空 token 无需挂入
跨线程 callback 链表。通用库仍保留这项能力；执行 Scope 本身也仍保留安全退休
规则，不能把 setValue 当作允许回收的时刻。

Client 静态大小为 **17,456 字节**（包含 16 KiB buffer），其中 Connection 1,032 字节；
Server 为 584 字节。对比库优化后仍使用 spawn 的节点 18,048 字节，下降 3.3%。
[布局原始输出](results/2026-09-20-layout-manual.txt)。

`test-echo` 现在还运行两个 Zig 测试，用 testing allocator 验证分配失败关闭 fd、
accept 失败后取消并释放已挂起的 Client；Debug/ReleaseFast 均通过。TCP 测试覆盖
--once 正常排空、reset 错误排空、半关闭及多客户端并行。

第二批同一组二进制比较：baseline 为本轮修改前，structured 为只改库且仍使用 spawn，
zigexec 为手工所有权版本。4 个并发场景 × 5 个实现 × 5 轮，共 100 次；其余计时
参数相同。单连接延迟已在第一批覆盖，第二批重点测并发热路径。

```sh
python3 benchmarks/build.py --baseline-snapshot .bench-cache/before-stdexec-round \
  --structured-snapshot .bench-cache/before-manual-echo
python3 benchmarks/run.py --libraries baseline,structured,zigexec,libxev,zio \
  --scenarios 64:32,64:256,4096:32,16384:32 \
  --output benchmarks/results/2026-09-20-manual-echo.json
```

## 第一批结果：只优化库，仍使用 spawn

单位 echo/s，五轮中位数；此批的 zigexec 是后续第二批的 structured。

| 消息 / 连接 | 修改前 | 只改库 | 改变 | libxev | zio |
|---|---:|---:|---:|---:|---:|
| 64 B / 1 | 97,095 | 94,988 | -2.2% | 97,193 | 96,964 |
| 64 B / 32 | 363,980 | 381,285 | +4.8% | 379,888 | 345,149 |
| 64 B / 256 | 327,605 | 348,653 | +6.4% | 348,767 | 341,240 |
| 4096 B / 1 | 86,040 | 86,355 | +0.4% | 86,421 | 87,840 |
| 4096 B / 32 | 299,048 | 301,751 | +0.9% | 315,861 | 285,086 |
| 16384 B / 32 | 245,925 | 255,251 | +3.8% | 253,915 | 244,941 |

此批 256 连接的中位数提升 6.4%，与 libxev 吞吐中位数接近；其他场景不能仅凭中位数
的小幅差异断言胜出。单连接 64 B 中位数下降 2.2%，各实现的 min–max 仍有重叠。
[完整区间及延迟/CPU](results/2026-09-20-stdexec-round.md)、
[120 次原始数据](results/2026-09-20-stdexec-round.json.gz)。所有负载计数和直方图均核对一致。

## 第二批结果：同批五方比较

单位 echo/s，五轮中位数。

| 消息 / 连接 | 修改前 | 只改库 | 手工 operation | libxev | zio | 手工版相对只改库 |
|---|---:|---:|---:|---:|---:|---:|
| 64 B / 32 | 366,275 | 369,132 | 373,083 | 384,215 | 349,334 | +1.1% |
| 64 B / 256 | 333,330 | 339,612 | 338,657 | 364,062 | 338,601 | -0.3% |
| 4096 B / 32 | 302,013 | 307,395 | 307,393 | 325,315 | 294,076 | -0.0% |
| 16384 B / 32 | 249,125 | 248,994 | 246,244 | 255,849 | 237,634 | -1.1% |

单独删除 spawn 等通用所有权机制后，四场景吞吐中位数相对只改库分别为 +1.1%、
-0.3%、约 0%、-1.1%，波动区间重叠。**当前数据不支持“手工分发显著提高 TCP 吞吐”**，
更不能宣称全面超过 libxev。64 B/256 的最终版与 zio 接近，在该批仍比 libxev 低约 7.0%。

两批中 baseline 及第三方库自己也有波动，不应把第一批 +6.4% 当作第二批一定重现的
固定收益，更不能把跨批差值相减来分解改动贡献。所有负载响应通过逐字节验证。

[完整吞吐区间、RTT、CPU、RSS](results/2026-09-20-manual-echo.md)、
[100 次原始数据与五份构建证据](results/2026-09-20-manual-echo.json.gz)。


## perf：开销确实减少，吞吐受内核成本限制

同批五个二进制，64 B / 256 连接，每个预热 2 秒、统计 10 秒，交错 3 轮。
通过 control FIFO 在稳态窗口启停计数，attach server 的所有已有线程，按经过
逐字节验证的 echo 数归一化。以下是每次 echo 的三轮中位数：

| 版本 | 用户态 cycles | 用户态 instructions | 内核态 cycles | 内核态 instructions |
|---|---:|---:|---:|---:|
| 修改前 | 953.61 | 1232.59 | 14320.17 | 13861.32 |
| 只改库，仍有 spawn | 663.53 | 1047.98 | 14424.82 | 13917.51 |
| 手工 operation | 557.43 | 869.73 | 14332.50 | 13752.45 |
| libxev | 154.71 | 279.52 | 14321.15 | 13938.38 |
| zio | 670.51 | 1186.40 | 14185.55 | 12589.92 |

库优化后用户态 cycles 下降 **30.4%**，手工分发在此基础上再下降 **16.0%**，
合计下降 **41.5%**；用户态 instructions 合计下降 **29.4%**。所以“删除开销”
是有硬件计数支持的，不只是代码更短或对象更小。

但减少的约 396 cycles 只占修改前用户态+内核态合计的约 **2.6%**。这解释了为什么
loopback 吞吐没有跟随用户态下降比例增长；批处理时机和内核网络工作也会变化。
不能把两个中位数之和视为逐轮精确分解，更不能把硬件 cycles 当作固定频率下的
纳秒数。内核计数包含任务运行期间被归属的中断/softirq 工作，不等于 /proc 的
进程 system CPU。通用 cache-misses 事件也不能直接解释成 DRAM miss 率。

手工版用户态成本仍约为 libxev 的 3.6 倍；我们保留了通用组合、repeat 重连和
执行退休协议，而 libxev 适配器直接重用 Completion。这轮没有加入线程局部
scope 专用类型，也没有改变 SQ/CQ 批量大小或 ring flags。后续应继续根据绝对
cycles 与内核路径拆分，而不是把剩余差距全归因于 sender/receiver 抽象。

```sh
python3 benchmarks/profile.py --libraries baseline,structured,zigexec,libxev,zio \
  --connections 256 --mode stat --seconds 10 --warmup 2 --repetitions 3 \
  --output .bench-cache/perf-stdexec-manual-stat
python3 benchmarks/profile.py --libraries baseline,structured,zigexec \
  --connections 256 --mode record --record-event cycles:u \
  --seconds 15 --warmup 2 --repetitions 1 --output .bench-cache/perf-stdexec-manual-user
```
