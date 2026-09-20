# zigexec 最终性能报告

2026-09-20 · AMD Ryzen 5 7500F · Linux io_uring · 单服务端核 TCP echo

## 结论

**在本次六个 TCP echo 场景中，最终 zigexec 的吞吐已接近 libxev，且多数场景高于 zio。**
相对 libxev，吞吐中位数差异为 **−1.9%～+2.0%**，各场景样本区间均有重叠，
不能据此宣称稳定超越。相对 zio，六个场景中五个中位数领先 **2.9%～9.1%**；
64 B 单连接为 −0.3%，基本接近。尾延迟没有对所有对照、所有场景都占优。

最后一轮协议优化已明确降低用户态执行成本：相对上一版手工管理 operation 的实现，
每次 echo 的用户态 cycles **下降 24.8%**，用户态指令数 **下降 33.8%**；
echo 根 Connection 从 **1032 B 降到 800 B（−22.5%）**。
这些是同批对照得到的结果，不能将 CPU 成本降幅直接解释为吞吐提升幅度。

本报告的“最终版”是当前工作区构建，而非原始 HEAD `7da66f5`。
被测 zigexec 二进制 SHA-256 为
`7f0d23c1b13d641fa7a4723efb158e9db9309bdc6242af1b960d2eeaeca290e6`。
原始数据包含完整构建清单、源码哈希、工作区 diff 及未跟踪源码，便于识别实际版本。

## 测量范围与环境

| 项目 | 设置 |
|---|---|
| CPU / 系统 | Ryzen 5 7500F，6 核 12 线程；Linux `7.2.4-arch1-2` |
| CPU 分配 | 服务端 CPU 1；客户端 CPU 2/3/4/5，均为不同物理核 |
| 调频 | `powersave` governor，正常动态调频；普通桌面开发机 |
| zigexec / zio 编译器 | Zig `0.17.0-dev.2127+e90365cd5` |
| libxev 编译器 | Zig `0.16.0`，对应其支持版本 |
| 编译方式 | LLVM，ReleaseFast，`-mcpu=native`；C 负载器 GCC `-O3 -march=native` |
| 主测试矩阵 | 4 个实现 × 6 个场景 × 5 次 = **120 次独立试验** |
| 计时 | 每次预热 1 秒，正式测量 3 秒；每次重启服务端，随机交错顺序 |
| 工作负载 | loopback TCP；每连接一个在途请求；16 KiB 服务端缓冲区；recv 后完整回写 |
| 校验 | 每次响应逐字节验证，支持分片和短写；计时前检查半关闭、并发、空闲连接与 reset/reconnect |

对照版本及后端配置：

| 名称 | 来源 | SQ / CQ | io_uring flags / 操作 |
|---|---|---|---|
| 最终 zigexec | 当前优化完成的工作区 | 64 / 64 | 0；recv/send |
| 迁移前 zigexec（baseline） | `before-completion-protocol` 快照，**已经手工管理 operation** | 64 / 64 | 0；recv/send |
| libxev | `9ce8e8e6ff89e583258a7f8e7adeeeaeae8611bf` | 64 / 128 | 0；recv/send |
| zio | `b3475afacc7674f01842a9b1e7499f0976972f22` | 256 / 256 | SINGLE_ISSUER、DEFER_TASKRUN、COOP_TASKRUN；recvmsg/sendmsg |

三者都限制为一个实际 I/O reactor / loop / executor。zigexec 主线程等待最终排空，
I/O 由一个 reactor 线程执行；所有服务端辅助线程继承同一 CPU affinity。
zio 使用公开运行时默认 ring 配置；libxev 与另外两者的编译器版本不同。
因此比较对象是这些固定实现与配置下的完整应用，不能把差异全部归因于
sender/receiver、callback 或协程抽象。

## 吞吐：完整六场景

单位为 **完整且通过校验的 echo/s**；各值取五次独立试验的中位数。
括号为相对指定对照中位数的差值，不是统计置信区间。

| 场景 | 最终 zigexec | libxev | zio | 相对 libxev | 相对 zio |
|---|---:|---:|---:|---:|---:|
| 64 B / 1 连接 | 95,528 | 95,921 | 95,851 | -0.4% | -0.3% |
| 64 B / 32 连接 | 377,159 | 381,786 | 345,744 | -1.2% | +9.1% |
| 64 B / 256 连接 | 356,402 | 349,528 | 343,920 | +2.0% | +3.6% |
| 4,096 B / 1 连接 | 87,405 | 87,489 | 84,929 | -0.1% | +2.9% |
| 4,096 B / 32 连接 | 310,771 | 316,701 | 289,922 | -1.9% | +7.2% |
| 16,384 B / 32 连接 | 253,760 | 256,680 | 245,211 | -1.1% | +3.5% |

![六场景吞吐，中位数与全部五次试验](results/2026-09-20-final-throughput.svg)

64 B / 256 连接下，zigexec 达到 **35.64 万 echo/s**，本批中位数比 libxev 高 2.0%；
但 zigexec 的范围为 33.83–35.88 万，libxev 为 34.66–36.59 万，无法由此确立稳定领先。
64 B / 32 与 4 KiB / 32 场景中，相对 zio 分别领先 9.1% 和 7.2%，且本批五次
样本区间不重叠，是本次对比中更清晰的应用级优势；仍需在其他机器和更长试验中验证普适性。

最后一轮协议迁移前后的同批对照如下：

| 场景 | 迁移前 → 最终 echo/s | 变化 | 迁移前 min–max | 最终 min–max |
|---|---:|---:|---:|---:|
| 64 B / 1 连接 | 97,079 → 95,528 | -1.6% | 94,563–98,071 | 94,579–97,981 |
| 64 B / 32 连接 | 375,833 → 377,159 | +0.4% | 371,787–393,625 | 371,762–395,935 |
| 64 B / 256 连接 | 337,650 → 356,402 | +5.6% | 334,974–356,444 | 338,255–358,762 |
| 4,096 B / 1 连接 | 88,156 → 87,405 | -0.9% | 86,246–88,966 | 85,939–91,920 |
| 4,096 B / 32 连接 | 306,446 → 310,771 | +1.4% | 302,355–314,501 | 307,313–317,131 |
| 16,384 B / 32 连接 | 256,882 → 253,760 | -1.2% | 246,280–259,106 | 247,193–263,393 |

64 B / 256 的中位数提升 5.6%，但各场景迁移前后区间仍重叠；其余场景变化为
−1.6%～+1.4%。因此，本批提供了高并发小消息获益的迹象，尚不足以宣称全场景稳定加速。
这与独立 perf 测出的用户态成本下降并不矛盾。

图中的点包含全部五次试验，没有挑选最好一轮。
[完整逐场景统计表](results/2026-09-20-final.md) 同时给出迁移前 baseline、
吞吐 min–max、单向 MiB/s、RTT、服务端 CPU 与 RSS。

## 延迟与进程资源

RTT 为客户端观测的完整往返延迟，包含内核和客户端事件循环。
下表为五次试验各自 p99 的中位数，使用向上取整的 1 µs 直方图桶；
不是把五次直方图合并后重新计算的 p99。

| 场景 | zigexec p99 | libxev p99 | zio p99 |
|---|---:|---:|---:|
| 64 B / 1 连接 | 14 µs | 14 µs | 14 µs |
| 64 B / 32 连接 | 110 µs | 111 µs | 116 µs |
| 64 B / 256 连接 | 914 µs | 875 µs | 925 µs |
| 4,096 B / 1 连接 | 16 µs | 16 µs | 17 µs |
| 4,096 B / 32 连接 | 137 µs | 143 µs | 137 µs |
| 16,384 B / 32 连接 | 164 µs | 154 µs | 169 µs |

64 B / 256 连接下，虽然本批吞吐中位数略高于 libxev，zigexec 的 p99 为 914 µs，
仍高于 libxev 的 875 µs；16 KiB / 32 的 p99 也高 10 µs。吞吐接近不代表尾延迟更优。

同样以 64 B / 256 为例，进程资源中位数如下：

| 指标 | zigexec | libxev | zio |
|---|---:|---:|---:|
| 服务端 CPU 占单核比例 | 66.3% | 65.7% | 66.0% |
| 服务端 CPU µs / echo | 1.86 | 1.88 | 1.92 |
| 进程 RSS | 2.96 MiB | 1.64 MiB | 5.40 MiB |

全部 120 次试验中，单个负载进程的 CPU 使用率最高约 50.2%，没有观察到负载核占满；
这不排除客户端调度和网络栈影响。16 KiB / 32 场景中，zigexec 单向 payload 吞吐约
**3965 MiB/s**，收发总量约为两倍；loopback 数字不能解释为物理网卡吞吐。

`/proc/PID/stat` CPU 时间包括服务端用户态及内核态线程，受系统 tick 量化影响；
它不包括独立内核 worker/softirq 的全部成本。RSS 是整个进程的结束时快照，
受缓冲区触页、运行时及分配器影响，不等于单个 operation 大小。
本测试为 closed-loop，延迟存在 coordinated omission，不能作为固定到达率下的生产 SLA。

## perf：优化究竟节省了什么

这是独立于上述吞吐测试的 perf 批次：64 B / 256 连接，各实现交错测量 3 次，
每次预热 2 秒、测量 10 秒；按通过校验的完整 echo 数归一化后取中位数。
该批次的 zigexec 与最终吞吐批次使用相同二进制。

| 实现 | 用户态 cycles / echo | 用户态 instructions / echo | 内核态 cycles / echo | io_uring_enter / echo |
|---|---:|---:|---:|---:|
| 迁移前 zigexec | 578.34 | 870.27 | 14161.92 | 0.03126 |
| 最终 zigexec | **434.87** | **575.96** | 14421.58 | 0.03125 |
| libxev | 149.46 | 279.24 | 13634.01 | 0.04688 |
| zio | 658.05 | 1187.50 | 14060.44 | 0.02751 |

![用户态成本：独立 perf 批次](results/2026-09-20-final-user-cost.svg)

1. **通用生命周期管理已不再主导用户态成本。** completion 允许销毁 operation 后，
   删除了通用执行 scope 的 acquire/release、父引用与完成后收尾保护。
   repeat 仅在下一轮经 trampoline，终态直接转发；静态不可取消环境消除无用 callback。
   用户态 cycles / instructions 分别减少 24.8% / 33.8%，是这些改动的合计，
   没有独立消融来给每项分配百分比。
2. **相对 libxev 仍有用户态差距。** 最终版用户态 cycles 约为 libxev 的 2.91 倍，
   指令数约为 2.06 倍；相对 zio 则分别少约 33.9% 和 51.5%。
   这些比例只适用于该 perf 场景，不等于吞吐比例。
3. **端到端受大量内核网络工作影响。** 被测服务端归属的内核态 cycles 远多于用户态。
   内核成本并未随这次协议迁移一起下降，因此用户态节省容易被内核、调频和运行波动盖过。
   内核计数还包括被归属的中断工作，不能等同于 `/proc` system CPU，更不是整机成本。
4. **批量提交已有效，但少 syscall 不保证更快。** zigexec 每次 echo 约 0.03125 次
   io_uring_enter，比 libxev 更少；zio 更少，也没有因此在所有吞吐场景领先。
   该 perf 批次所有实现的 futex/read/write syscall 和 CPU migration 计数均为 0。

硬件事件发生 multiplex（运行比例约 83%，perf 已缩放），三个样本不足以给出精密的
统计显著性结论。不同版本的中位数及不同事件中位数不应当作一次执行的可加分解，
也不应将 cycles 按假定固定频率直接换算成纳秒。

最终版用户态采样约 7K、无丢样：Scope 约 0.46%，trampoline 约 0.57%，repeat 约 2.58%；
热点主要落在 Request 初始化附近（约 32.67%）及 active 链表摘除附近（约 29.30%）。
源码行采样受内联和 skid 影响；这里给出的是剩余排查方向，不能把采样占比当作
删除该行即可获得的加速，也没有证据据此断言 DRAM 带宽瓶颈。

完整证据：[perf 统计](results/2026-09-20-completion-perf.md)、
[计数、采样报告、脚本和构建清单](results/2026-09-20-completion-perf.json.gz)、
[源码行采样](results/2026-09-20-completion-zigexec-lines.txt)。

## 内存布局与已完成的优化

以下是**最后一轮协议迁移前后**的静态类型布局，直接对真实 TCP echo 示例生成探针：

| 对象 | 迁移前 | 最终版 | 变化 |
|---|---:|---:|---:|
| Echo loop operation | 952 B | 760 B | −20.2% |
| 客户端根 Connection | 1032 B | 800 B | **−22.5%** |
| 完整 Client，含 16 KiB buffer | 17456 B | 17224 B | −1.3% |
| accept Connection | 496 B | 360 B | −27.4% |
| Server | 584 B | 448 B | −23.3% |

operation 的缩减是真实的，但在每连接 16 KiB buffer 的应用中，其占完整 Client 的比例
有限，不能把 −22.5% 声称为整个服务端内存下降。
[迁移前布局](results/2026-09-20-layout-manual.txt) /
[最终布局](results/2026-09-20-layout-completion.txt)。

最终版本包含整个优化过程保留下来的改进：

- 具体 receiver 与静态分发；原地 connect，operation 地址稳定到拥有者销毁它为止；
  普通算法不再重复存储 sender 与子 operation。
- 拥有者可保留 child，letValue 等继续借用结果；“completion 中允许销毁”不要求立即销毁，
  也没有为这次协议迁移增加 tuple 复制。
- repeat 使用 trampoline 驱动重复，仅终态直接通知；规范名称为 repeat，旧 effect 名称保留兼容别名。
- reactor 内提交无锁，跨线程 inbox 批量处理，取消按需扫描；真正的跨线程和取消协调保留。
- 单 reactor echo 手工管理 operation，不用 spawn 或每客户端异步计数；根排空仍正确管理。
- completion 销毁协议移除通用执行引用计数；编译期环境类型消除不需要的取消状态。
  Scope 兼容名保留为资源清理表，associate 仍保护异步下游的借用生命周期。

stdexec 是实现参考，固定研究版本为 `957a8331d992cb81dd00091aa5f9a9f2a60ec978`。
**没有测量 stdexec 的 TCP echo**，故不能声称超过 stdexec。
具体实现对照见 [协议迁移报告](COMPLETION.zh-CN.md)。

## 正确性与结论边界

最终源码在 Debug 和 ReleaseFast 均通过 **181/181** 个测试：156 核心、23 真实 io_uring、
2 echo；编译失败诊断、TCP 冒烟和 ReleaseFast 示例构建也通过。
新增测试覆盖通知中释放整个 operation 与嵌入 receiver、跨线程在 start 返回前销毁、
异步组合完成销毁，以及静态不可取消环境的零大小 callback。
借用地址一致、关联资源保护、同步十万轮、跨线程 repeat、短写、取消竞争与 ABA 测试保留。

主测试的四个服务端都先通过相同正确性门槛，120 次计时试验的 **87,882,741 次**完整响应也逐字节验证。
这提高了本次比较的可信度，但测试通过不代表已证明所有并发交错，也不替代 sanitizer 检查。

本报告覆盖单机 loopback、稳定连接、单服务端核和一个请求在途的 echo。
不覆盖文件 I/O、真实网络、TLS/HTTP、连接建立、跨线程调度压力、取消风暴或多核扩展。
不同编译器和 ring 配置是已披露的混杂因素；五次短试验提供可复查的样本范围，
不构成跨机器、跨负载的综合性能排名。

历史初始报告及中间轮次保留在仓库中，但本报告不把不同批次的吞吐相减，
也不将各轮优化百分比相乘来宣称累计加速。

## 复现与原始材料

```sh
# 编译当前三个实现；第四个 baseline 需要本机保存的迁移前快照
python3 benchmarks/build.py --baseline-snapshot .bench-cache/before-completion-protocol
python3 benchmarks/run.py --libraries baseline,zigexec,libxev,zio \
  --repetitions 5 --seconds 3 --warmup 1 \
  --output benchmarks/results/local-final.json

# 若没有旧快照，直接复现三个最终对照
python3 benchmarks/build.py
python3 benchmarks/run.py --libraries zigexec,libxev,zio \
  --repetitions 5 --seconds 3 --warmup 1 \
  --output benchmarks/results/local-three-libraries.json

# 静态布局；已有归档绘图（绘图需 matplotlib）
python3 benchmarks/layout.py
python3 benchmarks/plot_final.py
```

基线快照位于被 Git 忽略的 `.bench-cache/`，不是仓库公开文件；迁移前来源及 hash
随结果归档保存。不要用初始 HEAD 替代该快照后仍称之为“上一版协议”。
perf 复现参数见 [协议迁移报告](COMPLETION.zh-CN.md#复现)。

- [120 次最终吞吐试验原始数据](results/2026-09-20-final.json.gz)：每个负载进程的计数、
  延迟直方图、CPU、RSS、配置、来源及完整构建信息。gzip 为无损压缩。
- [全部统计表](results/2026-09-20-final.md)、[吞吐图 SVG](results/2026-09-20-final-throughput.svg)、
  [用户态成本图 SVG](results/2026-09-20-final-user-cost.svg)。
- [二进制一致性记录](results/2026-09-20-completion-code-identity.json)；最终报告校验记录见
  [验证记录](results/2026-09-20-final-validation.json)。
- [测试方法](README.md)、[初始历史报告](REPORT.zh-CN.md)、
  [第一轮优化](OPTIMIZATION.zh-CN.md)、[stdexec 对照及手工分发](STDEXEC.zh-CN.md)。
