# 2026-09-20：优化后 zigexec 的 perf 分析

剩余差距主要来自用户态执行协议的维护成本：scope 的递归原子计数、提交队列与
取消注册的互斥锁、取消链表扫描，以及嵌套 repeat 的驱动。具体 receiver 和原地
构造已经消除了此前的主要空间浪费，但不会自动消除这些有跨线程语义的操作。

本次只增加剖析脚本和报告，没有修改库源码。测量使用上一轮优化后的相同二进制；
源码与二进制 SHA-256 均与构建清单核对。对象为 libxev、zio 与优化后 zigexec，
不再把优化前版本当作当前实现。

## 方法

- Ryzen 5 7500F，Linux 7.2.4-arch1-2，perf 7.2.6-1；服务器 CPU 1，客户端
  CPU 2/3/4/5，物理核分离。编译器、SQ 配置和依赖固定版本沿用
  [优化报告](OPTIMIZATION.zh-CN.md)。
- `perf stat`：64 B，32/256 连接，每实现每场景 3 次，预热 2 秒、测量 10 秒，
  共 18 次，按固定随机顺序交错运行。计数归一化为每个验证成功的完整 echo。
- `perf record`：256 连接，每实现各做一次全态 `cycles` 和一次 `cycles:u`
  专项采样，预热 2 秒、采样 15 秒，499 Hz，DWARF 8 KiB 调用栈；共 6 份。
  6 份报告均为 0 lost samples。用户态专项用于避免全态采样中用户态样本过少。
- attach 到服务器 PID 及当时已有线程；客户端不纳入计数。通过 control FIFO
  在预热后 enable、测量结束时 disable，记录命令发出与 ACK 的时间。
  最后定向发送 SIGINT 让 perf 写完数据；退出码 -2 是该停止方式的结果。
- 三个实现先通过共同 TCP 正确性检查，负载器逐字节验证全部响应。
- 内核计数使用已有非交互 sudo 权限，不修改 perf_event_paranoid、NMI watchdog
  或其他系统配置。六个硬件事件约 83% 时间复用，表中采用 perf 缩放后的计数。
  软件/tracepoint 事件为完整计数。

采样和 syscall tracepoint 本身有开销。本次吞吐仅用于归一化与交叉检查，正式
性能比较以[上一轮无 perf 的交错测量](results/2026-09-19-optimized.md)为准。
内核 cycles 包含该任务运行时执行的网络中断/softirq 等工作，不能视为库自身
内核代码的成本，也不能与 `/proc/PID/stat` 的 CPU 时间直接互换。

## 每次 echo 的实际成本

下表为 64 B／256 连接，三个独立计数轮次的中位数：

| 每次 echo | zigexec | libxev | zio |
|---|---:|---:|---:|
| 用户态 cycles | 954 | 144 | 665 |
| 用户态 instructions | 1,233 | 274 | 1,187 |
| 内核态 cycles | 14,549 | 14,333 | 14,181 |
| 内核态 instructions | 13,956 | 13,827 | 12,572 |
| io_uring_enter 次数 | 0.0313 | 0.0469 | 0.0272 |
| 用户态 branch-misses | 0.393 | 0.417 | 2.360 |
| 通用 cache-misses:u 事件 | 32.91 | 3.56 | 24.51 |

与 libxev 相比，zigexec 每次 echo 约多执行 **4.5 倍用户态指令、消耗 6.6 倍
用户态周期**。内核指令数量很接近，且 zigexec 的 io_uring_enter 次数更少。
所以“对 libxev 的差距主要因为系统调用次数多”不符合此次数据。

与 zio 相比，zigexec 用户态指令只多约 **3.9%**，但周期多约 **43.5%**。
额外周期与原子操作、依赖链式内存访问和较差缓存行为的热点一致；仅凭这几个
事件不能精确分解每种 stall 的贡献。分支错误预测数量没有显示 zigexec 是
最差者，不能把差距笼统归因于分支预测。

32 连接时，zigexec/libxev/zio 的用户态 cycles 分别约 **682 / 116 / 526**，
用户态指令约 **1,168 / 252 / 1,217**。从 32 增至 256 连接，zigexec 的用户态
指令只增长约 5.6%，周期增长约 39.9%；通用 cache-misses:u 从约 0.99 增至
32.91。并发提高后，指令工作量之外的内存访问成本变得更明显。通用 cache
事件在本机映射为 `cpu/event=0x64,umask=0x09/`，不能直接当作 DRAM 访问次数、
字节数或某一级缓存的 miss rate。

18 次稳态计数中，三个实现的 `sys_enter_futex`、`sys_enter_read`、
`sys_enter_write` 都为 0，CPU migrations 也为 0。io_uring 数据传输不会计作
read/write syscall；这里的零值说明没有观察到前一版本那类 eventfd 自唤醒，
也没有看到 futex 阻塞成为热路径。互斥锁的用户态原子指令仍然有真实成本。

完整数值及 perf 下的吞吐见[归一化计数表](results/2026-09-20-perf.md)。

## 用户态热点落在哪里

`cycles:u` 专项采样，以下占比的分母是 **zigexec 用户态周期**，不是整台机器、
不是全部服务器周期。按源文件/源码行归并，数值有采样和行号归属误差。

| 路径 | 用户态周期约占比 | 解释 |
|---|---:|---|
| `execution/scope.zig` | 25.5% | enter/leave 递归更新父作用域的原子计数，处理退休边界 |
| `detail/sync.zig` | 22.1% | mutex 的 compare-exchange / exchange；主要是无竞争快路径 |
| `context.zig:217–219` | 18.7% | 每轮遍历 active 请求，读取 result、cancel_sent、cancel_requested |
| `algorithms/repeat_effect.zig` | 13.2% | work 原子计数、迭代驱动与重新启动 |

前四项约占用户态的 79.5%。`context.zig` 全文件占 24.6%，表中仅列了其中
取消扫描相关行，因此不能再把 24.6% 作为另一项相加。

全态 `cycles` 采样中，用户态分别约占 zigexec **6.29%**、libxev **1.00%**、
zio **5.16%**；其余主要是内核 TCP/IP、skb 分配释放、io_uring 等路径。
因此，取消扫描的 18.7% 用户态占比大致对应整体的 1% 左右，而不是删除扫描
就能提升整体吞吐 18.7%。不同采样轮次相乘仅用于量级理解，不是加速承诺。

### 1. 生命周期保证正在变成每个 I/O 的原子账单

[`Scope.enter/leave`](../src/execution/scope.zig) 递归操作 parent。
echo 外层 `repeatEffect` 创建迭代 scope，
[`sendAll`](../src/io/operations/send_all.zig) 内部又用
`just → letValue → then → repeatEffectUntil` 实现短写重试。因此一次 send
会经过内层迭代、外层迭代、根 scope；acquire/release 需要沿链更新。

这些操作保护“结果已经发布、生产者仍可能访问 operation”的退休语义。
即使业务只有一个 reactor 线程，泛型实现仍允许其他线程完成和取消，编译器
必须保留 atomic。换成静态 receiver 并不会自动消除这种协议成本。

libxev 的这个适配器直接在 read/write 回调中复用一个 Completion，完成后
设置下一次操作；没有给每一轮 echo 建立这套嵌套执行退休协议。差别是本次
程序实际执行的维护工作不同，不代表 sender/receiver 抽象必然要求这么多操作。

### 2. 本线程提交已经不唤醒自己，但仍要锁队列

[`Context.submit/pop`](../src/backends/io_uring/context.zig) 每个请求仍走
mutex 入队、mutex 出队。`runTasks/isClosing/hasQueued` 也有锁。
[`StopCallback.init/deinit`](../src/cancellation/callback.zig) 在每次 I/O
前后锁住 stop source，注册与移除回调。

本机反汇编能看到 `lock cmpxchg`、`xchg`，scope/repeat 对应原子 RMW。
无 futex 不代表这些指令免费。采样 IP 也可能落在原子指令之后的分支上，
不能把该行全部解释为分支错误预测；具体指令的 skid 是此次剖析的限制。

### 3. 没有取消也访问所有 active 请求

[`Context.run`](../src/backends/io_uring/context.zig) 每轮从 `self.active`
遍历全部在途请求。请求嵌在各连接 operation 内，不是连续紧凑的数组。
256 个连接时，要不断追踪 next 并读取跨连接状态；热点准确落在这些读操作附近。

这值得改进，但此前取消扫描隔离实验没有稳定的端到端收益，本次采样也显示
它只占整体约 1% 量级。应把“存在可测热点”与“改完必定明显领先”分开。

### 4. zio 的内核路径确实还不一样

zio 使用 SQ256、CQE 缓冲 256，并配置 `SINGLE_ISSUER`、`DEFER_TASKRUN`、
`COOP_TASKRUN`；zigexec 为 SQ64、CQE 批量 64、ring flags=0。
本次 zio 在 256 连接的 enter 次数与内核指令都更低。批处理与内核任务运行方式
是有证据支持的后续排查方向，但本次没有把这些配置分别做消融，不能把内核差距
全部归因于某一个 flag。直接复制 SINGLE_ISSUER 也不正确：zigexec 目前在主线程
创建 ring，在 worker 使用，需要先处理创建线程与使用线程的约束。

## 下一步优化顺序

1. **本线程队列与跨线程 inbox 分开。** reactor 的连续 recv/send 提交使用本地
   队列；跨线程发布保留同步、唤醒和 shutdown 语义，按批转移请求。目标是每个
   本线程请求不再反复支付入队/出队锁。
2. **减少嵌套执行退休的维护次数。** 优先专门实现 sendAll 的短写状态机，避免
   为通常一次成功的 send 再套通用 repeat；必须保留旧回调退出后才复用 request、
   取消 CQE 排空与缓冲区生命周期。进一步研究单线程执行域或批量持有 scope。
   不能直接把通用 atomic 改成普通整数，也不能提前释放根 operation。
3. **按取消事件触发扫描或维护待取消队列。** 避免正常收发时遍历全部 active，
   但需处理取消与提交竞争、SQ 满时重试、shutdown 和地址复用。
4. **独立比较 CQ 批量、SQ 大小和 ring flags。** 保持前面机制不变再测内核路径，
   避免把多个改动的收益混在一起。

此时再单纯压缩 then/receiver 布局不是最高优先级。空间优化已经有效，剩余
性能取决于每份工作需要执行多少同步、取消、退休和内核处理；这些都可以继续
优化，并不需要据此否定静态组合架构。

## 复现与原始数据

```sh
python3 benchmarks/profile.py --mode stat --connections 32,256 \
  --seconds 10 --warmup 2 --repetitions 3 --output .bench-cache/perf-local-stat
python3 benchmarks/profile.py --mode record --connections 256 \
  --seconds 15 --warmup 2 --repetitions 1 --output .bench-cache/perf-local-record
python3 benchmarks/profile.py --mode record --record-event cycles:u \
  --connections 256 --seconds 15 --warmup 2 --repetitions 1 \
  --output .bench-cache/perf-local-user
```

每次使用新的输出目录；脚本拒绝覆盖已存在的采样目录。要求 perf 以及能非交互
运行 perf/定向 kill 的 sudo。脚本不设置内核参数。统计脚本与早期全态采样脚本
版本略有不同，各次实际脚本、SHA-256、构建清单与命令均保存在归档中。

- [完整计数、每次负载结果、符号/源码行报告、脚本和构建清单](results/2026-09-20-perf.json.gz)
- [用户态源码行热点](results/2026-09-20-perf-user-zigexec-lines.txt)
- [全态模块占比](results/2026-09-20-perf-record-zigexec-dso.txt)
- 原始 perf.data 保留在 `.bench-cache/perf-2026-09-20-{record,user}/`，每库每份
  约 60 MiB，未把大二进制采样文件加入仓库。报告中的完整文本结果已无损存档。

```sh
sudo -n perf report --stdio --no-children --no-inline --call-graph none \
  -s srcline \
  -i .bench-cache/perf-2026-09-20-user/zigexec-c256-record-0/perf.data
```
