# 并发结果：tuple 与 union

[English](combinators.md) | **简体中文**

`whenAll` 拼接完成参数，`whenAny` 传递一个 tagged union。结果类型在编译期确定，
算法本身不分配堆内存；普通 `then` 和 `letValue` 的返回约定保持不变。

## whenAll：拼接完成参数

```zig
const Add = struct {
    pub fn call(_: @This(), left: i64, right: i64) i64 {
        return left + right;
    }
};
const task = ex.whenAll(.{ ex.just(20), ex.just(22) });
const answer = (try task.then(Add, .{}).syncWait(.{})).?[0]; // 42
const pair = (try task.syncWait(.{})).?; // .{ 20, 22 }
```

与 [P2300 的 when_all](https://eel.is/c++draft/exec.when.all) 一致，按输入顺序
拼接各分支的成功参数，再作为独立参数传给下一级 `then` callback 或 `letValue` 工厂：

```zig
const result = (try ex.whenAll(.{
    ex.just(@as(i64, 20)),
    ex.just(.{ true, @as(u8, 22) }),
}).syncWait(.{})) orelse return;
// result 类型为 tuple { i64, bool, u8 }，值为 .{ 20, true, 22 }。
// 若后接 then，其 call 接收 (self, number: i64, flag: bool, byte: u8)。
```

`syncWait` 将完成参数打包为返回的 tuple。库内部的 `SenderType.Values` 也用
一个 tuple 表示这些参数，供 operation 稳定存储及 `setValue(*const Values)` 协议使用。
这个存储 tuple 不会变成额外的业务参数：普通 `call` 会展开它。
如果业务函数希望整体接收参数，仍可显式使用 `callTuple(self, values)`。

空分支不贡献参数；`whenAll(.{})` 以零参数成功完成，`syncWait` 返回非 null 的空 tuple。
嵌套的 `whenAll` 同样拼接参数。若 `then` 业务函数主动返回一个 tuple 值，
它仍作为一个参数保留，不会递归展开其字段。

所有分支都会启动。某分支 error/stopped 会请求其他分支停止，并等待全部分支完成；
最终 error 优先于 stopped，报告最先观察到的错误。与普通组合链一样，
根 receiver 的 `setFinished` 还会等待生产者执行真正退出。

`ex.WhenAll(.{ A, B })` 是 sender 类型构造器；`ex.meta.ValuesOf(SenderType)`
或 `SenderType.Values` 取得完整成功参数 tuple 类型。
`meta.ValueOf` 仅适用于恰好有一个成功参数的 sender。

## whenAny：传递一个 tagged union

```zig
const race = ex.whenAny(.{
    .read = ex.io.recv(context, socket, buffer, 0),
    .timeout = ex.io.sleepFor(context, 5 * std.time.ns_per_s),
});
const Handle = struct {
    pub fn call(_: @This(), result: ex.meta.ValueOf(@TypeOf(race))) !usize {
        return switch (result) {
            .read => |values| values[0],
            .timeout => error.Timeout,
        };
    }
};
const bytes = (try race.then(Handle, .{}).syncWait(.{})) orelse return;
```

命名输入的字段名就是 union tag。每个分支 payload 为它的**完整成功 tuple**：
单值分支仍包装为单元素 tuple，无值的 timer 是空 tuple。
也接受 tuple 输入，此时 tag 为 `.@"0"`、`.@"1"` 等；需要 switch 时建议命名输入。

**最先观察到的完成通道获胜**，包括 value、error、stopped。
只有 value 产生 union，error/stopped 仍通过原来的独立通道传递。
后来的错误不会覆盖已经获胜的成功结果。竞争按实际 callback 顺序决定，
不承诺公平；同步分支按声明顺序启动。所有分支都会启动，即使 token 已请求停止。

确定赢家后请求其他分支停止，并等待**所有分支执行退出**才调用下游。
因此 recv 与 timer 的竞争会等内核取消请求收尾，再允许下游复用 buffer。
不响应取消的分支可能无限拖延整体完成；这不是强制超时或后台遗留任务。
外部 stop 同样是协作请求，不会覆盖已经确定的赢家。

类型构造器接受包含 sender 类型的命名 struct 或 tuple **类型**：

```zig
const Io = ex.io.For(*ex.IoUring);
const Race = ex.WhenAny(struct { read: Io.Recv, timeout: Io.SleepFor });
const Result = ex.meta.ValueOf(Race);
```

空输入和非 sender 分支在编译期报错。算法不会把业务函数返回的 tuple/union
解释成 sender 图。`then` 返回 tuple 或 tagged union 时，它就是一个普通值；
`letValue` 工厂仍返回 sender 或 `!sender`。

## 所有权边界

聚合结果构造在 operation 存储中，指针和 slice 仍是浅拷贝，不延长所指对象生命周期。
`whenAny` 分支执行退出后，内嵌 operation 与关联资源仍保持到下游消费结束。
`repeatEffect` 的每一轮有独立的退休边界。

算法不自动析构用户资源。失败的 `whenAll` 会丢弃其他分支的成功值，
`whenAny` 输掉的分支也可能已打开文件或接受 socket。应在分支中安排清理，
或通过覆盖整个图的显式 owner 管理资源。不能通过 `syncWait` 返回指向
operation 内部存储的指针，因为返回后该 operation 已不再存在。
