# 重复执行

[English](repeat.md) | **简体中文**

## repeat

```zig
const task = effect.repeat();
```

effect 必须成功完成为 **空 tuple**。每次成功后，算法重新 connect 并启动同一个 sender 描述；error/stopped 原样结束整个重复操作。repeat 本身不会成功结束，因此通常配合取消或一个表示结束的错误，再按业务语义恢复。

```zig
const Tick = struct {
    count: *usize,
    pub fn call(self: @This()) void { self.count.* += 1; }
};
const task = ex.just(.{}).then(Tick, .{&count}).repeat();
_ = try task.syncWait(.{ .allocator = allocator, .stop_token = source.token() });
```

上例是同步循环，需要另一个线程请求停止。每轮开始前检查 stop token；已经启动的异步子任务仍通过自己的取消协议收尾，不会被直接丢弃。

## repeatUntil

```zig
const Tick = struct {
    count: *usize,
    limit: usize,
    pub fn call(self: @This()) bool {
        self.count.* += 1;
        return self.count.* == self.limit;
    }
};
const task = ex.just(.{}).then(Tick, .{ &count, 100 }).repeatUntil();
_ = try task.syncWait(.{ .allocator = allocator });
```

effect 必须成功完成为 **一个 bool**：false 重复，true 结束并产生空成功 tuple。至少执行一次，除非启动前已取消；error/stopped 直接结束。类型不匹配在编译期给出专门诊断。

两者都提供自由函数、sender 链式方法、deferred 子链方法和 `Repeat(S)/RepeatUntil(S)` 类型构造器。

## 状态、调度与生命周期

重新连接会从原 sender 描述创建新的子 operation；callback 的按值捕获会随之重新初始化。跨轮累积状态通过显式指针或稳定的外部拥有者保存，示例中的 count 就是这种状态。allocator 和 stop token 从最终 receiver 转发。

重复执行共用 `TrampolineScheduler` 的线程局部状态，默认允许 16 层、约 4096 字节栈距离内的嵌套执行，超过阈值则加入 intrusive FIFO，由最外层调度调用排空。不同 sender 类型、嵌套 repeat 使用同一队列；不再用每个 repeat 的原子 work 计数防递归。栈距离是调度点之间的阈值，不限制用户 callback 自身的栈用量。

completion 允许立即重建 child，不再有 iteration 或父 scope 的执行计数。生产者通知后不得再访问自身，包括另一线程在 start 返回前完成的情况。仅下一轮进入 trampoline，终态直接转发。每轮的关联资源清理记录仍保留，不含执行原子计数。测试覆盖同步十万轮、嵌套重复、跨线程完成、取消、错误及 completion 内回收整个 receiver/connection。

`ex.TrampolineScheduler{ .max_depth = 16, .max_stack_bytes = 4096 }` 也可独立用于 `schedule`、`startsOn` 和 `continuesOn`。当前线程已有 trampoline 时，采用最外层调度的限制。`repeatEffect`／`repeatEffectUntil` 及对应大写类型名称保留为兼容别名，新代码使用 `repeat`／`repeatUntil`。

算法不自动更换线程或插入调度点。纯同步的无限 effect 会持续占用当前线程，需要公平调度时，应在 effect 内显式加入 scheduler。正常的 io_uring effect 会在等 I/O 时归还执行权。

## TCP echo 与短写

[echo 示例](../examples/tcp_echo.zig) 的连接内循环是：

```zig
const body = Io.recv(self.context, self.socket, &self.buffer, 0)
    .letValue(EchoChunk, .{self})
    .then(DiscardCount, .{})
    .repeat()
    .uponError(PeerError, .{});
```

EchoChunk 在收到 EOF 时返回 EndOfStream，PeerError 把 EOF 和客户端 I/O 错误恢复为空成功。
Client 在根 operation 的完成接收函数中摘链、关闭 fd 并释放自身（包含 buffer）。
上一轮 sendAll 结束后才启动下一轮 recv。

外层 repeatUntil 驱动 accept：Dispatch 直接连接、启动新的 Client operation，
随后继续接受下一条连接，不等待上一条结束。所有客户端只在 reactor 上操作；
--once 在首次接入后停止 accept，但主线程等待该 Client 完全退出。
分配失败会关闭刚接收的 fd；accept 链失败则 shutdown context 并排空已有客户端。
此示例不用 spawn 或 CountingScope。

`io.sendAll(context, fd, buffer, flags)` 内部用 repeatUntil 重试短写，成功返回完整字节数。空 buffer 直接返回 0；非空 buffer 的 send 返回 0 则报告 WriteZero。取消和错误可能发生在已经发出部分数据之后，不保证事务式发送。它借用 buffer 到完成，不额外分配内存；调用方按需提供 MSG.NOSIGNAL 等 socket flags。
