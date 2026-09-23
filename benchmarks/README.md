# zigexec / libxev / zio TCP benchmark

最新六场景对比、perf、内存布局、微基准及结论见
[性能报告（2026-09-23）](PERFORMANCE.zh-CN.md)。其余阶段报告保留为历史记录。

这是 Linux loopback TCP 的端到端对比，不是所有异步工作负载的综合排名。
测试对象是 zigexec 的现有 TCP echo 示例、libxev 的公开 TCP watcher API，以及
`lalinsky/zio` 的完整协程运行时。三个服务端都执行 `recv → 完整回写 → recv`，
每条连接一个 16 KiB 缓冲区，支持短读、短写和 EOF，不做逐请求日志。

## 微基准（框架自身开销）

TCP echo 的服务端 CPU 未饱和，主要成本在内核 loopback 与客户端，难以区分库的差异。
`benchmarks/micro.zig` 不经过网络协议栈，直接测量 sync_wait、repeat、whenAll、
RunLoop/ThreadPool 调度以及 io_uring nop 循环（附手写 io_uring 精简实现对照）：

```sh
zig build bench -Doptimize=ReleaseFast -Dcpu=native            # 全部
zig build bench -Doptimize=ReleaseFast -Dcpu=native -- io_uring # 按名称过滤
```

每行为 7 次运行的中位数（ns/op）；[本机完整结果](results/2026-09-23-micro.md)
包含所有项目和样本范围。可配合
`perf stat -e cycles:u,instructions:u zig-out/bin/zigexec-micro <filter>`
观察整段运行的用户态计数。

## 复现

需要 Linux x86_64、允许使用 io_uring、Python 3.12+、Git、GCC、taskset，以及
项目要求的 `Zig 0.17.0-dev.2127+e90365cd5`：

```sh
python3 benchmarks/build.py
python3 benchmarks/run.py --output benchmarks/results/local.json
```

`build.py` 把固定版本的依赖下载到被 Git 忽略的 `.bench-cache/`。libxev 当前
支持 Zig 0.16，因此脚本会下载并校验官方 Zig 0.16.0 的 SHA-256；也可以通过
`--zig016 /absolute/path/to/zig` 指定已有编译器。zio 使用官方 `zig-0.17` 分支的
固定提交。不会改动第三方源代码或安装全局依赖。

默认服务端绑定逻辑 CPU 1，四个负载进程分别绑定 CPU 2/3/4/5。运行前根据
`lscpu -e=CPU,CORE,SOCKET` 选择机器上的不同物理核；脚本拒绝使用 SMT 兄弟核：

```sh
python3 benchmarks/run.py --server-cpu 1 --client-cpus 2,3,4,5 \
  --seconds 3 --warmup 1 --repetitions 5 \
  --output benchmarks/results/local.json

# 只验证服务端正确性
python3 benchmarks/run.py --verify-only

# 检查负载器能处理分片，且不会把错误回包计为成功
python3 benchmarks/test_load.py

# 自定义工作负载或只测一个实现
python3 benchmarks/run.py --libraries zigexec --scenarios 64:1,4096:32
```

可重复运行 `build.py`，然后用相同参数重新测量修改后的 zigexec。正常的
`zig build` 和 `zig build test` 不会下载、编译或运行这些比较依赖。

## 方法与统计口径

- 三者均使用 LLVM、`ReleaseFast`、`-mcpu=native`；负载器使用 GCC `-O3 -march=native`。
- 一个服务端占用一个物理核。最终 zigexec 的主线程在 RunLoop 中等待最终排空，实际 I/O
  由一个 reactor 线程处理；libxev 一个 loop；zio 一个 executor。辅助线程也继承
  相同的 CPU affinity。没有用 zio 默认配置以外的忙轮询或关闭调度指标等优化。
- 三者强制使用 io_uring；不允许失败后悄悄回退 epoll。zigexec 使用 64 个
  SQ entries，默认请求 SINGLE_ISSUER、DEFER_TASKRUN、COOP_TASKRUN；若内核拒绝
  这些 flags，则回退为无 flags 的 io_uring。已发布基线和 libxev 使用无 flags
  的 64-entry ring。zio Runtime 使用默认 256-entry ring。SQ 大小不是连接数
  或在途请求数的上限；这些配置差异会影响性能。
- 客户端用原生 C + epoll；Python 只负责启动、同步和收集结果。连接数为 1 时
  一个负载进程，其他默认场景使用四个进程。所有连接在计时前建立，统一起跑，
  先预热 1 秒，再测 3 秒，每个场景 5 次。服务器在每次试验中重新启动。
- 每条连接同一时刻只有一个未完成请求，消息大小为 64 B、4 KiB 或 16 KiB。
  客户端启用 `TCP_NODELAY`，服务端保持默认 Nagle 行为，监听 backlog 均为 64。
  无应用层流水线、TLS、HTTP 或人为延迟。
- 每轮随机打乱场景及库的顺序，随机种子固定；服务器试验串行执行。
- 每条消息都有变化的序号和数据内容，每次完整响应逐字节校验；错误直接使运行
  失败。正式测量前，三者还必须通过 1 MiB 二进制分片、半关闭、32 并发连接加
  空闲连接、reset/reconnect 检查。
- 吞吐计数仅包含**请求开始与响应完成都在测量窗口内**的完整 echo。启动、连接
  建立、预热和结束排空不算入吞吐。每条连接跨窗口的边界请求最多漏计两个；
  这是小幅保守的有限窗口估计。
- `echoes/s` 是完整往返数；`MiB/s` 是单方向 payload 吞吐，收发总字节量约为
  两倍。延迟是客户端观测 RTT，包含内核和客户端事件循环开销。
- RTT 每次记录，以向上取整的 1 µs 桶统计 p50/p95/p99；最后一桶为 ≥1 秒，
  精确均值与最大值另存。表中的 p99 是五次试验各自 p99 的中位数。
- CPU 来自 `/proc/PID/stat` 的进程级用户态+内核态时间差，包括 zigexec reactor。
  100% 表示占满一个逻辑 CPU；CPU 时间有系统 tick 的量化误差。RSS 是计时结束
  时整个进程的快照，包含运行时和缓冲区，不能解释为库对象的精确内存成本。
  CPU 统计不包含独立内核 worker/softirq 的全部工作，不能视为整机网络栈总成本。
- JSON 保存每次试验、每个负载进程的计数与延迟直方图、CPU 使用、版本、完整
  构建命令、源码与二进制 SHA-256、CPU 和内核信息。Markdown 汇总中位数及
  吞吐 min–max，不只报告最好的一轮。

## 解释边界

libxev 使用 Zig 0.16，另外两者使用 0.17；不同编译器/标准库是混杂因素。
配置对齐的是公开 API 下的应用行为和 CPU 配额，运行时功能、ring 配置、内存
布局、内核调用策略不完全相同。这里不是对 sender/receiver、callback、协程
三种抽象本身做纯粹成本归因。

这是一台普通开发机上的 loopback、closed-loop steady-state 测试，连接建立
成本被排除；系统调频、其他进程、内核网络栈也影响结果。closed-loop 延迟
会受到 coordinated omission 影响，不能作为生产环境固定到达率下的 SLA。
客户端 CPU 使用率一并保留，用于检查负载端是否明显耗尽预算；低 CPU 使用率
本身也不能证明客户端绝无影响。

结果不覆盖文件 I/O、定时器、跨线程调度、取消风暴、多核扩展或真实网络，
也不支持“优于所有市面异步库”这一结论。若修改优化路径，应先保持生命周期
和取消语义正确，再用本套相同参数比较。

## 优化前后同批比较

```sh
python3 benchmarks/build.py --baseline-ref 69bc11b80db0b8ac4dc63fe748ac35b81a696cc7
python3 benchmarks/run.py --libraries baseline,zigexec,libxev,zio \
  --output benchmarks/results/local-optimized.json
```

`baseline` 来自指定提交的独立缓存源码，`zigexec` 来自当前工作区。四个实现
按相同场景交错执行；默认 5 轮 × 6 场景 × 4 实现，共 120 次。构建清单保存
两份源码的 SHA-256，当前改动的完整 diff，以及所有二进制 hash。

## 历史后端开销对照实验

以下实验针对优化前 `7da66f5` 的库源码及同版本测试；当前已实现 local-wake，
脚本会明确拒绝在新源码上重放历史替换。请使用上面的同批比较命令测当前版本。

```sh
python3 benchmarks/diagnose.py --seconds 2 --warmup 0.5 --repetitions 5
```

脚本只在 `.bench-cache/diagnostics/` 中复制并修改源码，正式 `src/` 不变。
四个变体分别为 `local-wake`（reactor 内 submit 不写 eventfd）、`cancel-scan`
（仅发生取消或关闭时扫描 active 链表）、`combined`（前两项叠加）和 `ring256`
（仅增大 SQ）。每个变体先运行现有核心、真实 io_uring 测试及共同 TCP 正确性检查，
再与原版、libxev、zio 交错重测。结果保存每个变体的完整 context 源码及二进制 hash。
这些是性能归因实验，测试通过也不等于对全部并发交错的正确性证明，不自动作为
生产修复合入。隔离变体的结果不混入三库主比较表。

`python3 benchmarks/layout.py` 会在缓存目录生成布局探针，直接复用真实 echo
示例的类型，报告 sender、operation、Connection 和 spawn 节点的静态字节数。
当前结果见 [布局记录](results/2026-09-23-layout.txt)；它不等同于 RSS。

已记录的本机结果及分析见 [2026-09-19 报告](REPORT.zh-CN.md)，
逐场景完整表见 [结果表](results/2026-09-19-ryzen7500f.md)，
原始数据见 [JSON.gz](results/2026-09-19-ryzen7500f.json.gz)。存档采用无损 gzip
压缩；可用 `gzip -dc benchmarks/results/2026-09-19-ryzen7500f.json.gz` 读取，
运行脚本本身仍生成未压缩 JSON，方便后续分析。

原地构造与具体 receiver 的实现、API 迁移、布局和同批四方比较见
[优化报告](OPTIMIZATION.zh-CN.md)。

## perf 剖析

最新硬件计数见 [2026-09-23 perf 统计](results/2026-09-23-perf.md)；
历史热点采样与解释见 [2026-09-20 perf 分析](PERF.zh-CN.md)。`profile.py` 只剖析已有构建产物，
不修改库源码或内核配置；通过 FIFO 把 perf 事件限定在稳态计时窗口。


## stdexec 对照优化与工作区快照

第二轮的源码对照、trampoline／repeat、批量提交和取消扫描优化，以及新的同批结果，
见 [stdexec 优化报告](STDEXEC.zh-CN.md)。

若基线包含尚未提交的改动，在改动或重新构建之前保存当前 `zigexec-echo` 和
`build.json` 到同一个目录，再使用：

```sh
python3 benchmarks/build.py --baseline-snapshot /absolute/path/to/snapshot
python3 benchmarks/run.py --libraries baseline,zigexec,libxev,zio \
  --output benchmarks/results/local-next-round.json
```

快照模式校验旧二进制 hash，并把旧 manifest 嵌入新结果；不能与 `--baseline-ref`
同时使用。结果中的 `baseline` 始终以该次 build manifest 为准。


若要额外保留“库已优化、示例仍使用结构化任务”的对照，传入
`--structured-snapshot /path/to/snapshot`，并在 run.py/profile.py 中加入
`structured`。它与 baseline 一样校验原始二进制和 manifest。
