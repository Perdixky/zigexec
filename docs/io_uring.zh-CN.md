# io_uring 后端

[English](io_uring.md) | **简体中文**

`ex.IoUring.init(allocator, .{ .entries = 64 })` 创建 context、eventfd 与一个 reactor 线程；ring 由 reactor 自己创建，初始化错误在 `init` 返回前传回。所有 SQ/CQ 操作由 reactor 执行，跨线程提交通过受锁保护的 intrusive inbox，由 reactor 批量摘取；本 reactor 的重入提交在 SQ 有空位且前面没有排队请求时直接写入 SQE，否则进入本地队列；两条路径都不加锁、不写 eventfd。取消使用原子标记，跨线程取消通过 eventfd 唤醒。无需 `std.Io` 或 liburing，直接使用 Zig 的低层 `std.os.linux.IoUring`。

## API 与内核需求

`ex.io` 提供 `readSome/writeSome/recv/send/openAt/close/fsync/accept/connect/sleepFor`；这些 sender 依赖 context 协议，不直接依赖 io_uring。

context 大小必须为 2 或更大的 2 的幂，受内核 ring 大小限制。初始化要求 `IORING_FEAT_SINGLE_MMAP`（Zig wrapper 要求）、`IORING_FEAT_NODROP` 与 `IORING_ASYNC_CANCEL_ANY`（Linux 5.19+，启动时探测），缺失时返回 `error.SystemOutdated`；应使用支持所需 opcode 的现代 Linux。

默认以 `SINGLE_ISSUER | DEFER_TASKRUN | COOP_TASKRUN`（Linux 6.1+）创建 ring：内核把完成相关的 task work 攒到 reactor 带 `GETEVENTS` 进入 ring 时再执行，而不是打断它；每次 `io_uring_enter` 都带 `GETEVENTS`。内核拒绝这些 flag 时回退为不带 flag 的 ring；`.defer_taskrun = false` 可显式关闭。部署时还须允许 io_uring 系统调用；权限/内核不支持会作为初始化错误返回，不隐式切换到阻塞 I/O。

当前在 Linux `7.2.4-arch1-2`、Zig `0.17.0-dev.2127+e90365cd5` 上进行了真实测试。未对旧内核逐版本验证；新 opcode 不可用会通过该操作的错误通道报告。

常用参数约定：

- offset 是 `u64`；`io.current_offset` 表示使用文件的当前偏移。
- `openAt` 的 flags 是原始 POSIX/Linux `u32` 位掩码，可由 `@bitCast(linux.O{...})` 构造；mode 为权限位。
- `accept` 成功返回新 fd；`connect` 借用 sockaddr 和长度。
- `send` 自动加 `MSG_NOSIGNAL`，使断开的连接返回错误而非终止进程。
- `sleepFor` 使用相对单调时钟纳秒数；超时对应正常完成。
- `readSome/writeSome/recv/send` 只做一次传输，允许短传输。没有隐含的 read-exact/write-all 循环。

## 完成与内存生命周期

buffer、路径、地址和文件描述符必须活到 sender 完成。传输成功发送字节数，open/accept 发送 fd，无值操作发送空 tuple。EOF 是正常的 0 字节成功，内核错误映射为 Zig 错误，例如 `BadFileDescriptor`、`FileNotFound`、`ConnectionReset`；不识别的 errno 为 `UnexpectedIoError`。当前错误通道不携带原始 errno 数值。

成功获得的 fd 由调用方拥有。`whenAll` 在其他分支失败时会丢弃成功值，而 Zig 不自动析构；不要依赖它自动清理已取得的 fd。安排每个分支自己的资源清理，或用明确的 owner/defer 管理句柄。

operation 嵌入后端 Request，提交与取消不额外分配请求节点。内核仍可能为请求分配资源；这里只承诺库代码不为每个请求显式分配堆节点。

## 取消与 CQE 追踪

1. sender 启动时注册环境 token 的 stop callback。
2. callback 先标记 `cancel_requested`，再设置 context 的 `cancel_dirty`；只有跨线程取消写 eventfd，不接触 SQ/CQ。
3. 未提交的请求可直接停止；在途请求提交 `ASYNC_CANCEL`。
4. 原请求和取消请求分别携带 user_data，最低位标识取消 CQE。
5. 已提交取消时，两个 CQE 全部收齐后才通知 receiver 并释放 Request。

sender 启动时，只有 stop token 确实可能触发时才把请求标记为 `cancellable`；只有这类请求进入 active 链表，普通 I/O 不会写入相邻 operation 的缓存行。没有取消事件时不遍历 active 链表。有取消事件时扫描一次；SQ 满则保留 dirty 标志，下一轮继续。扫描前消费标志，因此与扫描并发的新取消会触发下一轮，不会丢失。当前仍是事件触发的 O(active) 扫描，并非 stdexec 的逐请求取消任务队列。

最后一步保证迟到的取消不会引用已被复用的 operation 地址，也保证内核不再借用 buffer。`-ECANCELED` 进入 stopped；若原操作已经成功，仍可发送成功，取消不是抢占或事务回滚。

在最终通知前解除 stop callback，因此其他线程上已经开始的取消调用也会收尾。根 receiver 可以在最终完成通知中回收 connection；通知后不再访问 request、receiver 或 operation。

## 提交压力与唤醒

SQ 大小限制一次提交的批次，不限制在途请求数。SQ 满时保留用户请求并先提交现有批次，不伪造 `SubmissionQueueFull` 完成，也不等待挂起读取结束才提交后面的写入/取消。

本地普通调度任务也按批次执行；重入排队的任务留到下一轮，避免立即递归或阻塞等待丢失本地工作。跨线程 submit 与 shutdown 共用 admission 锁，关闭前已接受的 inbox 会被处理。

eventfd 的 poll 始终优先保留/重建，避免 ring 满时失去跨线程唤醒能力。请求队列或待提交取消不为空时，继续非阻塞提交批次；没有这些工作时才等待 CQE。

要求 NODROP，内核 CQ 满时可保留溢出的完成项；消费 CQ 并刷新溢出队列。取消提交优先于新 I/O，但没有跨请求公平性或有界队列长度承诺：请求节点由使用方的 operation 持有。

## 关闭与错误

`shutdown()` 可从任意线程调用，包含 reactor 回调：关闭新提交，取消队列中和在途请求，并等待实际完成。此方法自身不 join。队列中的请求以 stopped 完成；在途请求（无论是否 cancellable）由一次 `ASYNC_CANCEL_ANY | ASYNC_CANCEL_ALL` 提交取消。观察到 shutdown 后不再提交新请求，因此这一次取消即可覆盖全部请求。

`deinit()` 调用 shutdown、join worker、销毁 ring 并关闭 eventfd。不可从 reactor 自身调用；context 必须活到其他线程上的 submit/cancel/shutdown 调用返回。内核不可中断的工作可能延长关闭时间，不能承诺固定的取消延迟。

关闭后的新请求为 `error.ContextClosed`。无效 fd 等常规操作失败走 sender 的 error 通道。`io_uring_enter` 的中断/暂时资源压力会重试；无法恢复的 ring 基础设施损坏会 panic，而不是虚构完成后释放仍被内核使用的 buffer。

continuation 默认运行在 reactor 线程。不要在该线程阻塞调用 `syncWait` 等待同一 context；耗时处理应 `continuesOn(cpu_scheduler)`。

## 测试

`zig build test-io` 独立运行真实内核测试，包括文件内容/EOF、内核错误、定时器、socketpair、loopback connect/accept、在途取消、关闭取消、2 条目 ring 下 128 个读取排队、100 轮地址复用、completion 内释放 connection，以及共享 timer 的所有权。测试不会静默跳过受限内核。

## 完整发送与 echo

`sendAll(context, fd, buffer, flags)` 基于普通 send 重试短写，两次 send 之间经 trampoline 继续；成功返回 buffer.len，非空写入无进展时报 WriteZero。错误/取消发生前可能已经发送部分数据。该操作借用 buffer 到完成。TCP 客户端异常关闭时可使用 linux.MSG.NOSIGNAL。

可运行的 [TCP echo 示例](../examples/tcp_echo.zig) 使用 repeat 驱动连接内循环，启动命令为 `zig build run-echo -- 9000`，回环测试为 `zig build test-echo`。

服务只有一个 accept 循环，Dispatch 在 reactor 回调里手工连接并启动每条 Client
operation。每个 Client 拥有独立 buffer 和 Connection，普通 intrusive 链表记录存活节点，
completion 摘链并关闭 fd、释放内存。此单线程示例不用 spawn、CountingScope 或
每连接 stop source；完成通知允许回收 operation，不再维护通用执行计数。
`--once` 接入一条后等待它退出。accept 失败通过 context shutdown 取消在途 I/O，
收齐真实完成后退出。测试包含分配失败 fd 清理、accept 失败排空，以及 32 并发加空闲连接。
