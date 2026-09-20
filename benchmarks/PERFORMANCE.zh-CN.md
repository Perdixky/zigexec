# zigexec 最新性能报告

2026-09-20 · AMD Ryzen 5 7500F · Linux io_uring · 单服务端核 TCP echo

## 结论

本轮在最新 cleanup/lifetime 实现上重新构建并测量了 zigexec，以已发布提交
`71ab83b` 为交错运行的基线。在六个 TCP echo 场景中，最新 zigexec 相对该基线的
吞吐中位数变化为 **-1.8%～+0.9%**；所有样本区间均有重叠，不能据此宣称新机制
带来了稳定的吞吐提升或回退。

相对 libxev，最新 zigexec 的吞吐差异为 **-3.3%～+0.0%**；相对 zio，三个场景
领先 1.4%～8.6%，另外两个场景落后 0.8%，64 B 单连接基本持平。尾延迟也没有
对全部实现和场景占优。这是固定版本、固定配置下的 TCP echo 应用对比，不是异步库的
综合排名。

独立 perf 批次中，最新实现相对 `71ab83b` 的用户态 cycles / echo 增加 **7.1%**，
instructions / echo 增加 **2.0%**。静态布局也因显式 cleanup 链有所增大，例如客户端根
Connection 从 800 B 增至 864 B。新机制解决的是 operation 复用前的异步资源清理语义；
本轮数据不支持把它描述为性能优化。

被测版本是提交前的当前工作区，zigexec 二进制 SHA-256 为
`fe44c0d8634fee2ac5738f01879a3a186d61b5a687d8468ef71611d3df2e41af`。
原始归档包含构建清单、源码哈希、工作区 diff 和未跟踪源码，可识别实际被测内容。

## 测量范围与环境

| 项目 | 设置 |
|---|---|
| CPU / 系统 | Ryzen 5 7500F，6 核 12 线程；Linux `7.2.4-arch1-2` |
| CPU 分配 | 服务端 CPU 1；客户端 CPU 2/3/4/5，均为不同物理核 |
| 调频 | `powersave` governor，正常动态调频；普通桌面开发机 |
| zigexec / zio 编译器 | Zig `0.17.0-dev.2127+e90365cd5` |
| libxev 编译器 | Zig `0.16.0`，对应其支持版本 |
| 编译方式 | LLVM，ReleaseFast，`-mcpu=native`；负载器 GCC `-O3 -march=native` |
| 主测试矩阵 | 4 个实现 × 6 个场景 × 5 次 = **120 次独立试验** |
| 计时 | 每次预热 1 秒、测量 3 秒；每次重启服务端，固定种子随机交错顺序 |
| 工作负载 | loopback TCP；每连接一个在途请求；16 KiB 缓冲区；recv 后完整回写 |
| 校验 | 响应逐字节验证；计时前检查分片、半关闭、并发、空闲连接和 reset/reconnect |

对照版本及后端配置：

| 名称 | 来源 | SQ / CQ | io_uring flags / 操作 |
|---|---|---|---|
| 最新 zigexec | 本轮当前工作区 | 64 / 64 | 0；recv/send |
| baseline | 已发布提交 `71ab83b` | 64 / 64 | 0；recv/send |
| libxev | `9ce8e8e6ff89e583258a7f8e7adeeeaeae8611bf` | 64 / 128 | 0；recv/send |
| zio | `b3475afacc7674f01842a9b1e7499f0976972f22` | 256 / 256 | SINGLE_ISSUER、DEFER_TASKRUN、COOP_TASKRUN；recvmsg/sendmsg |

四者都限制为一个实际 I/O reactor / loop / executor。zio 使用公开运行时默认 ring 配置；
libxev 使用不同 Zig 版本。因此差异不能全部归因于 sender/receiver、callback 或协程抽象。

## 吞吐：完整六场景

单位为通过校验的完整 echo/s；各值取五次独立试验的中位数。括号中的百分比是相对
指定对照中位数的差值，不是置信区间。

| 场景 | baseline | 最新 zigexec | libxev | zio | 相对 baseline | 相对 libxev | 相对 zio |
|---|---:|---:|---:|---:|---:|---:|---:|
| 64 B / 1 连接 | 97,314 | 95,534 | 95,514 | 96,292 | -1.8% | +0.0% | -0.8% |
| 64 B / 32 连接 | 374,998 | 378,263 | 383,079 | 348,203 | +0.9% | -1.3% | +8.6% |
| 64 B / 256 连接 | 340,677 | 338,908 | 344,997 | 341,788 | -0.5% | -1.8% | -0.8% |
| 4,096 B / 1 连接 | 86,551 | 86,743 | 88,990 | 85,546 | +0.2% | -2.5% | +1.4% |
| 4,096 B / 32 连接 | 308,292 | 309,310 | 319,708 | 289,155 | +0.3% | -3.3% | +7.0% |
| 16,384 B / 32 连接 | 249,915 | 248,216 | 254,954 | 236,779 | -0.7% | -2.6% | +4.8% |

![六场景吞吐，中位数与全部五次试验](results/2026-09-20-final-throughput.svg)

最新 zigexec 相对 baseline 的各场景范围如下。六组区间全部重叠；短试验中的小幅中位数
变化应视为噪声与实现差异共同作用的结果。

| 场景 | baseline min–max | 最新 zigexec min–max |
|---|---:|---:|
| 64 B / 1 连接 | 95,390–101,114 | 95,302–100,393 |
| 64 B / 32 连接 | 374,351–399,531 | 374,384–398,605 |
| 64 B / 256 连接 | 337,620–360,227 | 334,809–356,839 |
| 4,096 B / 1 连接 | 84,680–88,741 | 84,099–88,927 |
| 4,096 B / 32 连接 | 305,842–310,504 | 304,157–321,044 |
| 16,384 B / 32 连接 | 248,151–263,591 | 247,745–254,392 |

图中的点包含全部五次试验，没有挑选最好一轮。[完整统计表](results/2026-09-20-final.md)
还给出单向 MiB/s、RTT、服务端 CPU 与 RSS。

## 延迟与进程资源

RTT 是客户端观测的完整往返延迟。下表为五次试验各自 p99 的中位数，使用向上取整的
1 µs 直方图桶，并非合并五次直方图后重算。

| 场景 | 最新 zigexec p99 | libxev p99 | zio p99 |
|---|---:|---:|---:|
| 64 B / 1 连接 | 14 µs | 14 µs | 14 µs |
| 64 B / 32 连接 | 111 µs | 109 µs | 116 µs |
| 64 B / 256 连接 | 973 µs | 966 µs | 954 µs |
| 4,096 B / 1 连接 | 16 µs | 15 µs | 16 µs |
| 4,096 B / 32 连接 | 142 µs | 129 µs | 151 µs |
| 16,384 B / 32 连接 | 166 µs | 160 µs | 177 µs |

64 B / 256 连接时，最新 zigexec 的服务端 CPU 中位数为 66.3%，约 1.95 µs/echo，
RSS 为 2.96 MiB。对应 libxev 为 65.3%、1.90 µs/echo、1.64 MiB；zio 为
66.3%、1.93 µs/echo、5.40 MiB。RSS 是进程结束时快照，不等于 operation 大小。

`/proc/PID/stat` 计入服务端用户态及内核态线程，但不覆盖独立内核 worker/softirq 的
全部成本。本测试是 closed-loop，延迟存在 coordinated omission，不能当作固定到达率下的 SLA。

## perf：用户态执行成本

这是独立 perf 批次：64 B / 256 连接，四个实现交错测量 3 次，每次预热 2 秒、测量
10 秒。硬件计数按通过校验的 echo 数归一化后取中位数。

| 实现 | 用户态 cycles / echo | 用户态 instructions / echo | 内核态 cycles / echo | io_uring_enter / echo |
|---|---:|---:|---:|---:|
| baseline (`71ab83b`) | 415.45 | 576.12 | 14427.08 | 0.03125 |
| 最新 zigexec | **445.14** | **587.86** | 14333.08 | 0.03125 |
| libxev | 143.43 | 269.10 | 14198.99 | 0.04688 |
| zio | 704.07 | 1187.53 | 14104.48 | 0.02739 |

![用户态成本：独立 perf 批次](results/2026-09-20-final-user-cost.svg)

最新实现相对 baseline 的用户态 cycles 增加 7.1%，instructions 增加 2.0%；相对 zio
分别少 36.8% 和 50.5%，相对 libxev 则仍明显更高。端到端主要成本落在内核网络路径，
所以用户态变化不会按相同比例反映到吞吐。

硬件事件发生 multiplex，运行比例约 83%，perf 已进行缩放。三个样本不足以给出精密的
统计显著性结论；不同事件的中位数也不能拼成某一次执行的可加分解。
[完整 perf 统计](results/2026-09-20-final-perf.md)和
[原始计数、脚本与构建清单](results/2026-09-20-final-perf.json.gz)随仓库归档。

## 内存布局

静态探针直接针对真实 TCP echo 示例。baseline 数值来自 `71ab83b`，最新数值来自本轮代码：

| 对象 | baseline | 最新版 | 变化 |
|---|---:|---:|---:|
| Echo loop operation | 760 B | 824 B | +8.4% |
| 客户端根 Connection | 800 B | 864 B | +8.0% |
| 完整 Client（含 16 KiB buffer） | 17224 B | 17288 B | +0.4% |
| accept Connection | 360 B | 392 B | +8.9% |
| Server | 448 B | 480 B | +7.1% |

新增空间来自 operation 图上的显式 cleanup 能力。它允许 operation 在存储重用前异步清理
子 operation 拥有的资源，并保证 continuation 只在清理链完成后运行。这是生命周期正确性
设计，不应由当前结果包装成内存或速度优化。完整 Client 仍主要由 16 KiB buffer 构成。

[baseline 布局](results/2026-09-20-layout-completion.txt) /
[最新布局](results/2026-09-20-layout-latest.txt)。

## 正确性与边界

最新源码在 Debug 与 ReleaseFast 均通过 181/181 个测试，包括核心、真实 io_uring 和 TCP
echo；四个 benchmark 服务端也通过共享正确性门槛。120 次计时试验共逐字节验证
**87,668,875 次**完整响应。这提高了本次比较的可信度，但不等于穷尽所有并发交错。

本报告只覆盖单机 loopback、稳定连接、单服务端核、每连接一个在途请求的 echo。不覆盖
文件 I/O、真实网络、TLS/HTTP、连接建立、取消风暴或多核扩展。不同编译器和 ring 配置是
已披露的混杂因素；五次短试验不构成跨机器、跨负载的性能排名。

## 复现与原始材料

```sh
python3 benchmarks/build.py --baseline-ref 71ab83b0b188f6806b97fb270893016aee7dba81
python3 benchmarks/run.py --libraries baseline,zigexec,libxev,zio \
  --repetitions 5 --seconds 3 --warmup 1 \
  --output benchmarks/results/local-final.json

python3 benchmarks/profile.py --libraries baseline,zigexec,libxev,zio \
  --connections 256 --bytes 64 --mode stat --seconds 10 --warmup 2 \
  --repetitions 3 --output .bench-cache/perf-local
python3 benchmarks/summarize_profile.py .bench-cache/perf-local \
  --json benchmarks/results/local-perf.json.gz \
  --markdown benchmarks/results/local-perf.md

python3 benchmarks/layout.py
python3 benchmarks/plot_final.py \
  --throughput benchmarks/results/2026-09-20-final.json.gz \
  --perf benchmarks/results/2026-09-20-final-perf.json.gz
```

- [120 次吞吐试验原始数据](results/2026-09-20-final.json.gz)与
  [完整统计表](results/2026-09-20-final.md)。
- [perf 原始数据](results/2026-09-20-final-perf.json.gz)与
  [计数摘要](results/2026-09-20-final-perf.md)。
- [吞吐图 SVG](results/2026-09-20-final-throughput.svg)与
  [用户态成本图 SVG](results/2026-09-20-final-user-cost.svg)。
- [本轮验证记录](results/2026-09-20-final-validation.json)。
- [测试方法](README.md)、[初始历史报告](REPORT.zh-CN.md)、
  [第一轮优化](OPTIMIZATION.zh-CN.md)、[stdexec 对照](STDEXEC.zh-CN.md)。
