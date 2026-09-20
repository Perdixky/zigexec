# Completion 可销毁协议与编译期取消优化

优化完成后补测的六场景对比与综合结论见 [最终性能报告](PERFORMANCE.zh-CN.md)。

日期：2026-09-20。对照是上一轮已经采用手工 operation 分发的 TCP echo，
不是最初包含 spawn 的实现。保留前几轮的具体 receiver、原地连接、借用 tuple、
reactor 本地无锁提交、批量处理和事件触发的取消扫描。

## 已实现

- 根 Connection、I/O source、调度节点等统一遵守 completion 中允许销毁 operation
  的协议。通知之后不再访问 operation；不再提供 setFinished 通知。
- 删除通用执行 scope 的 active 原子计数、父引用、start-return 保护及 I/O/schedule
  acquire/release。另一个线程可在 start 返回前完成并销毁根及嵌入的 receiver。
- repeat 在完成中重建子操作，仅下一轮经 TLS trampoline；成功、错误、停止终态
  直接转发。它不再保存一个稍后派发的完成 action，不需要 iteration 原子计数。
- letValue、continuesOn、whenAll 等继续拥有 child，保留已有借用结果优化。
  **可以销毁不等于必须销毁**；此迁移不要求复制 tuple，也不强制前后阶段共用 union。
- `EnvOf(R)` 保留具体环境类型；`UnstoppableEnv`/`NeverStopToken` 使 I/O、共享订阅
  和各算法外层停止 callback 成为零大小类型。syncWait/spawn 的字面量环境省略 token
  时自动采用该类型。动态 Env 与显式 stop token 继续支持取消；readEnv 和显式旧
  erased Receiver 是有意保留的环境擦除边界。
- spawn 在完成接收函数中释放节点，再释放独立关联；split 持有共享引用直至所有
  订阅通知结束；whenAny 等待所有分支 completion，再转发。真正的并发计数保留。
- associate 为保护异步下游借用仍注册资源清理动作。兼容名 Scope 现在只有清理表，
  无执行引用计数。根完成前将动作复制到栈，完成回调可释放整个 operation，随后
  仅使用独立动作释放关联。whenAny 分支共享外层清理表，repeat 按轮提取记录。

清理表保留的注册锁用于并发资源关联，不是每次 I/O 的原子入口。旧自定义 sender
必须把自身访问移到 completion 前，并将原 setFinished 中的回收合并到对应完成
接收函数。完整协议与环境用法见 [生命周期文档](../docs/lifetimes.zh-CN.md)。

## 核对的 stdexec 实现

固定版本 `957a8331d992cb81dd00091aa5f9a9f2a60ec978`：

- [repeat_until.hpp](https://github.com/NVIDIA/stdexec/blob/957a8331d992cb81dd00091aa5f9a9f2a60ec978/include/exec/repeat_until.hpp#L70)：receiver 在终态 cleanup 后直接转发，重复时重连带 trampoline 的子链。本轮采用这个完成边界，未照搬 C++ 虚基类布局。
- [trampoline_scheduler.hpp](https://github.com/NVIDIA/stdexec/blob/957a8331d992cb81dd00091aa5f9a9f2a60ec978/include/exec/trampoline_scheduler.hpp#L214)：通过 unstoppable_token 编译期分支跳过停止检查。对应采用具体环境类型和零大小 callback。
- [__let.hpp](https://github.com/NVIDIA/stdexec/blob/957a8331d992cb81dd00091aa5f9a9f2a60ec978/include/stdexec/__detail/__let.hpp#L181)：保存所需参数，再在 variant 中替换前后阶段。本库继续持有两阶段 operation，因此无需为协议迁移增加参数副本。
- [io_uring_context.hpp](https://github.com/NVIDIA/stdexec/blob/957a8331d992cb81dd00091aa5f9a9f2a60ec978/include/exec/linux/io_uring_context.hpp#L1031)：可取消 I/O 仍有原子在途计数和停止注册，最终通知前解除注册。本轮保留本库目标/取消 CQE 的协调与地址复用保护，未把它误判成可一并删除的开销。

没有测量 stdexec 的 TCP echo，因此本报告不声称已经达到或超过 stdexec 的性能。

## 验证

Debug 与 ReleaseFast 均通过 181 个测试（156 核心、23 io_uring、2 echo），
编译失败诊断及 TCP echo 冒烟测试也通过；ReleaseFast 示例构建通过。核心测试新覆盖：

- value/error/stopped 均可在通知中释放包含 receiver 的整块 allocation。
- 异步转交、repeat、whenAll、split 的完成可以销毁根。
- 另一个线程在源 start 返回前完成并销毁 operation。
- 不可取消 I/O 在适配器中传播环境类型，callback 大小为 0，布局实际减少。
- 环境字面量中的空/显式 stop token 仍兼容。

旧“completion 后继续访问自身”的测试 source 已改为先收尾再通知，避免让违反新
协议的 fixture 掩盖错误。64 KiB 借用地址一致、同步十万轮、跨线程 repeat、
关联保护异步下游、短写、取消竞争、ABA、断连与错误排空测试继续保留。

## perf：用户态成本下降

同机 Ryzen 5 7500F，Linux 7.2.4，LLVM ReleaseFast/native；server CPU1，client
CPU2–5。64 B / 256 连接，每个二进制交错测量 3 次，每次预热 2 秒、测量 10 秒。
按通过逐字节校验的完整 echo 数归一化，表格为各计数中位数。

| 实现 | cycles:u / echo | instructions:u / echo | cycles:k / echo |
|---|---:|---:|---:|
| 迁移前，手工 operation | 578.34 | 870.27 | 14161.92 |
| 新协议 + 静态环境 | 434.87 | 575.96 | 14421.58 |
| libxev | 149.46 | 279.24 | 13634.01 |
| zio | 658.05 | 1187.50 | 14060.44 |

用户态 cycles 减少 **24.8%**，instructions 减少 **33.8%**。这是整套改动的合计，
没有独立消融来分配“协议 / 终态 / 环境”各自收益。当前用户态仍高于 libxev，低于 zio。
内核计数存在变化与波动，不能继续套用上一批“内核仅差 11 cycles”的数字。
硬件事件有 multiplex，perf 已缩放；内核计数也包含被归属的中断工作。

新 cycles:u 采样约 7K、无丢样。源码行自耗时归因中，Scope 合计约 0.46%、
trampoline 约 0.57%、repeat 约 2.58%；此前分别约 39.91%、17.76%、11.84%。
Scope 原子指令已经删除，剩下的是资源清理检查。新的主要采样位置为 I/O Request
初始化（sender.zig:29，约 32.67%）及 active 链表摘除附近（context.zig:216，
约 29.30%）。这些是采样位置，受内联和 skid 影响，不是逐条指令的精确因果成本，
也不能把跨二进制采样百分比相减作为独立收益。

[计数详情](results/2026-09-20-completion-perf.md)、
[完整计数/采样报告/构建信息/脚本](results/2026-09-20-completion-perf.json.gz)、
[源码行采样](results/2026-09-20-completion-zigexec-lines.txt)。

## 独立吞吐对照

不挂 perf；每场景、每二进制交错 3 次，预热 1 秒、测量 3 秒，共 24 次。

| 场景 | 迁移前 | 新协议 | libxev | zio |
|---|---:|---:|---:|---:|
| 64 B / 256 连接 | 339545 | 340128 | 345781 | 339677 |
| 4096 B / 32 连接 | 317372 | 308179 | 317070 | 286025 |

单位 echo/s，中位数。新协议相对迁移前分别 **+0.2% / −2.9%**，运行区间均重叠。
本批没有证明稳定吞吐提升，也没有超过 libxev。用户态占整个 echo 执行成本的比例
较小，用户态成本下降不应直接换算成相同比例的 TCP 吞吐提升。

[吞吐、区间、RTT、CPU、RSS](results/2026-09-20-completion-echo.md)、
[24 次原始数据和构建快照](results/2026-09-20-completion-echo.json.gz)。

实际 echo 根 Connection 从 **1032 B → 800 B**（−22.5%）；包含 16 KiB buffer 的
Client 从 **17456 B → 17224 B**。Server 从 584 B → 448 B。
[布局输出](results/2026-09-20-layout-completion.txt)。

## 复现

基线快照保存在 `.bench-cache/before-completion-protocol`，包含二进制、构建 manifest
及当时 src/tests/examples/docs；结果归档也包含来源哈希、差异、未跟踪源码和命令。

```sh
python3 benchmarks/build.py --baseline-snapshot .bench-cache/before-completion-protocol
python3 benchmarks/profile.py --libraries baseline,zigexec,libxev,zio \
  --connections 256 --mode stat --seconds 10 --warmup 2 --repetitions 3 \
  --output .bench-cache/perf-completion-protocol
python3 benchmarks/profile.py --libraries zigexec --connections 256 \
  --mode record --record-event cycles:u --seconds 15 --warmup 2 --repetitions 1 \
  --output .bench-cache/perf-completion-user
python3 benchmarks/run.py --libraries baseline,zigexec,libxev,zio \
  --scenarios 64:256,4096:32 --repetitions 3 --seconds 3 --warmup 1 \
  --output benchmarks/results/2026-09-20-completion-echo.json
```

收尾兼容性修复后重新构建的 echo 与被测二进制 SHA-256 完全相同，
[校验记录](results/2026-09-20-completion-code-identity.json)。

重复执行请使用新的 output 目录，避免覆盖原始对照。
