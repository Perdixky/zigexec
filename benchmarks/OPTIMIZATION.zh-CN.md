# 2026-09-19：具体 receiver 与原地 operation 构造优化

本次修改将内建 sender 改为 `Operation(R)`，在最终地址递归构造已知子 operation，
并移除普通组合节点保存的上游 sender 副本。io_uring 的本线程 submit 也不再写
唤醒 eventfd。echo 的单连接节点静态大小从 102,392 字节降到 18,032 字节，
减少 82.4%。这是真实示例的类型布局，吞吐量另用相同工作负载实测。

## 实现范围

- 内建图中的 receiver 保留具体类型。`TypedReceiver(Values, R)` 只保存 R；
  指针 receiver 的句柄为 8 字节，不再为每层存储 context、完成函数表和 Env。
- `connectInto` 在最终存储地址初始化节点和已知子 operation。`then`、恢复、
  bulk、调度、取消包装、join、root 不再为延迟连接保留整棵上游 sender。
  `startsOn` 的任务也提前连接，真正执行仍等待调度完成。
- `letValue` 的工厂依赖运行时输入，因此下一节点在完成回调中连接；表达式
  `upstream()` 同样等待输入。现成 sender 形式在外层连接时构造，成功后才启动。
- `repeat` 为再次连接保留 sender 描述。第一轮在 connect 时构造，后续轮次仍
  等上一轮执行入口全部退出后才复用存储，保留同步 trampoline 和跨线程保护。
- scope join 与 shared 的异构等待队列只擦除队列通知入口，具体订阅 operation
  内的 receiver 不擦除。内核请求与取消回调仍使用各自的运行时入口。
- 旧自定义 sender 的固定 `Operation` / `connect` 可通过兼容桥接使用；桥接
  在固定地址保存具体 receiver，只有旧 sender 边界使用显式 `Receiver(Values)`。
- reactor 只在 `submit` 来自本 Context 的工作线程时省略 eventfd 写入。
  跨线程提交、调度任务、取消和 shutdown 的唤醒继续遵守原协议。
  本次没有改变 SQ64 配置，也没有应用未显示稳定收益的取消扫描实验。

具体 receiver 可以引用父状态；这与 P2300 的构造方式相容。构造函数的 `out`
是目标存储地址，并非额外传给子 sender 的父 operation 参数。Zig 不依赖 C++
guaranteed copy elision，而由显式原地构造建立地址稳定性。

## 布局

实际 `examples/tcp_echo.zig` 的 16 KiB 捕获，通过 `benchmarks/layout.py` 测量：

| 类型 | 优化前字节 | 优化后字节 |
|---|---:|---:|
| Echo factory | 16,400 | 16,400 |
| Echo loop operation | 2,168 | 936 |
| schedule.letValue(Echo) operation | 19,072 | 17,600 |
| 加 then(Close) | 35,632 | 17,616 |
| 加 uponError(CloseError) | 52,200 | 17,632 |
| 加 letStopped(CloseStopped) | 68,888 | 17,664 |
| 加 scope token wrapper | 85,656 | 17,864 |
| 根 Connection | 102,304 | 17,944 |
| spawn 节点同字段布局 | 102,392 | 18,032 |

16 KiB 捕获在普通组合树中只存一份；增加 then 或 uponError 各只增加 16 字节。
原 sender 值本身仍是可复制的描述；这里没有宣称构造阶段完全零复制。
另一个 64 KiB payload 探针的组合 operation 为 65,976 字节；该探针使用显式
擦除 receiver 作为末端，不能与 echo 节点或进程 RSS 直接等同。

## API 迁移

链式组合、syncWait 和 spawn 的调用方式不变。手工连接改为：

```zig
var operation: ex.Connection(@TypeOf(sender), @TypeOf(&receiver)) = undefined;
ex.connectInto(&operation, sender, &receiver);
operation.start();
```

`ex.connect` 是相同三参数签名的别名，不再返回 operation 值。
`meta.OperationOf(S, R)` 查询具体 raw operation；内建 sender 提供
`Operation(R)` 与 `sender.connectInto(&child, receiver)`。
连接后禁止移动或复制，即使尚未 start；连接不执行业务回调、不分配运行资源。
`setValue/error/stopped` 仍只发布结果，`setFinished` 才允许回收根存储。

## 验证

- `zig build test-all`：Debug 下 166/166 运行测试通过，编译失败诊断通过。
- `zig build test-all test-echo -Doptimize=ReleaseFast`：166/166 运行测试、
  编译失败诊断和实际 TCP echo 测试通过。
- `zig build -Doptimize=ReleaseFast`：所有示例构建通过。
- 新增 `tests/construction.zig`：已知子节点在 connect 构造且 start 不重连、
  工厂延迟构造、子地址稳定、16 KiB 捕获单份、具体 receiver 指针大小、旧 sender
  在异构 join 的兼容路径。原有借用结果、并发取消、重复重建、共享 owner 释放、
  setFinished 内释放堆节点、真实 I/O 地址复用等测试继续运行。
- 正式计时前，旧版、新版、libxev、zio 都通过同一套分片、半关闭、并发、
  reset/reconnect 和二进制内容校验；计时期间每个完整响应逐字节校验。

## 同批基准

使用同一台 Ryzen 5 7500F，服务端 CPU 1，客户端 CPU 2/3/4/5，LLVM / ReleaseFast /
本机 CPU 优化。旧版来自 `7da66f5acb89794366734bf25188a932030e6363`；
新版来自当前工作区，完整源码 diff 与 SHA-256 存入原始结果。
libxev、zio 的版本、编译器与配置沿用[原始报告](REPORT.zh-CN.md)。
每场景预热 1 秒、测量 3 秒、5 轮，四个实现交错，共 120 次。

```sh
python3 benchmarks/build.py --baseline-ref 7da66f5acb89794366734bf25188a932030e6363
python3 benchmarks/run.py --libraries baseline,zigexec,libxev,zio \
  --output benchmarks/results/2026-09-19-optimized.json
```

以下均为五轮中位数。旧版与新版来自同批交错测量。

| 消息 | 连接数 | 旧版 echo/s | 新版 echo/s | 提升 | libxev | zio | 新版相对 libxev / zio |
|---|---:|---:|---:|---:|---:|---:|---:|
| 64 B | 1 | 92,910 | 95,499 | +2.8% | 97,107 | 94,093 | -1.7% / +1.5% |
| 64 B | 32 | 319,504 | 382,969 | +19.9% | 396,722 | 346,482 | -3.5% / +10.5% |
| 64 B | 256 | 285,163 | 330,051 | +15.7% | 352,000 | 343,898 | -6.2% / -4.0% |
| 4096 B | 1 | 86,565 | 88,185 | +1.9% | 89,145 | 88,755 | -1.1% / -0.6% |
| 4096 B | 32 | 265,285 | 315,957 | +19.1% | 321,039 | 300,877 | -1.6% / +5.0% |
| 16384 B | 32 | 222,740 | 248,763 | +11.7% | 265,798 | 240,745 | -6.4% / +3.3% |

64 B／32 连接的 CPU 时间从 **2.16 降至 1.68 µs/echo**，减少 **22.4%**。
64 B／256 连接的进程 RSS 从 **23.01 降至 2.99 MiB**，减少 **87.0%**。
RSS 是已驻留页的进程快照，包括运行时、栈和缓冲区；分配容量、被实际触及的页与
静态类型大小不同，不能把 RSS 降幅解释为 operation 大小降幅。

新版在三个 32 连接场景的中位数都高于 zio；在本轮所有场景仍低于 libxev。
64 B／256 连接仍落后于 zio 约 4.0%、libxev 约 6.2%，尚不能宣称全面领先。
单连接结果及部分竞争实现的 min–max 有明显重叠，不能把小幅中位数差异视为
统计显著的排名。完整区间、RTT 和 CPU 指标保留在结果表中。

[完整结果表](results/2026-09-19-optimized.md)、[无损原始数据](results/2026-09-19-optimized.json.gz)、
[优化后布局](results/2026-09-19-layout-optimized.txt) 可用于复核。所有 120 次试验
的计数与延迟直方图一致，源码、构建脚本和二进制 SHA-256 与记录一致。

本轮同时包含 operation/receiver 改造与本线程唤醒优化，不能把全部吞吐收益归因
到其中一项。此前单独 local-wake 的对照支持消除自唤醒有收益，但不同批次数字
不能相减来精确分解两项贡献。此测试覆盖单 reactor 的 loopback 稳态 echo，
不覆盖建连开销、真实网络、多核、文件 I/O 或取消风暴。libxev 编译器为 0.16，
另外两者为 0.17；zio SQ256、其他 SQ64。它不是所有异步库的综合性能排名。
