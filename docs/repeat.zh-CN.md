# 重复执行

[English](repeat.md) | **简体中文**

## repeatEffect

```zig
const task = effect.repeatEffect();
```

effect 必须成功完成为 **空 tuple**。每次成功后，算法重新 connect 并启动同一个 sender 描述；error/stopped 原样结束整个重复操作。repeatEffect 本身不会成功结束，因此通常配合取消或一个表示结束的错误，再按业务语义恢复。

```zig
const Tick = struct {
    count: *usize,
    pub fn call(self: @This()) void { self.count.* += 1; }
};
const task = ex.just(.{}).then(Tick, .{&count}).repeatEffect();
_ = try task.syncWait(.{ .allocator = allocator, .stop_token = source.token() });
```

上例是同步循环，需要另一个线程请求停止。每轮开始前检查 stop token；已经启动的异步子任务仍通过自己的取消协议收尾，不会被直接丢弃。

## repeatEffectUntil

```zig
const Tick = struct {
    count: *usize,
    limit: usize,
    pub fn call(self: @This()) bool {
        self.count.* += 1;
        return self.count.* == self.limit;
    }
};
const task = ex.just(.{}).then(Tick, .{ &count, 100 }).repeatEffectUntil();
_ = try task.syncWait(.{ .allocator = allocator });
```

effect 必须成功完成为 **一个 bool**：false 重复，true 结束并产生空成功 tuple。至少执行一次，除非启动前已取消；error/stopped 直接结束。类型不匹配在编译期给出专门诊断。

两者都提供自由函数、sender 链式方法、deferred 子链方法和 `RepeatEffect(S)/RepeatEffectUntil(S)` 类型构造器。

## 状态、调度与生命周期

重新连接会从原 sender 描述创建新的子 operation；callback 的按值捕获会随之重新初始化。跨轮累积状态通过显式指针或稳定的外部拥有者保存，示例中的 count 就是这种状态。allocator 和 stop token 从最终 receiver 转发。

同步完成由循环驱动，不递归调用下一轮 start；异步完成通过原子计数转交驱动权。任一时刻只有一个子任务，该轮 completion 处理退出、子作用域空闲后才复用其 operation 存储。测试覆盖同步十万轮、跨线程完成、取消、错误以及最终 receiver 在 setFinished 回收 connection。

算法不自动更换线程或插入调度点。纯同步的无限 effect 会持续占用当前线程，需要公平调度时，应在 effect 内显式加入 scheduler。正常的 io_uring effect 会在等 I/O 时归还执行权。

## TCP echo 与短写

[echo 示例](../examples/tcp_echo.zig) 的连接内循环是：

```zig
const body = ex.upstream()
    .letValue(Receive, .{&connection})
    .letValue(EchoChunk, .{&connection})
    .then(DiscardCount, .{})
    .repeatEffect();
```

EchoChunk 在收到 EOF 时返回 EndOfStream，外层 FinishConnection 负责释放 buffer、关闭 fd，并把 EOF/客户端 I/O 错误恢复为空成功；OutOfMemory 继续传播并停止服务，stopped 路径清理后仍传递停止。上一轮 sendAll 结束后才启动下一轮 recv。

更外层的 repeatEffectUntil 驱动 accept：连接结束后接受下一条，--once 则在首条连接结束后返回 true。整个服务是一张执行图，main 只在最后 syncWait 一次。

`io.sendAll(context, fd, buffer, flags)` 内部用 repeatEffectUntil 重试短写，成功返回完整字节数。空 buffer 直接返回 0；非空 buffer 的 send 返回 0 则报告 WriteZero。取消和错误可能发生在已经发出部分数据之后，不保证事务式发送。它借用 buffer 到完成，不额外分配内存；调用方按需提供 MSG.NOSIGNAL 等 socket flags。
