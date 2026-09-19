# 执行环境与 allocator

[English](allocators.md) | **简体中文**

## stdexec 的设计依据

核对日期：2026-09-18。主要依据为 [P2300R10](https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2024/p2300r10.html) 和 NVIDIA/stdexec 当前实现。

- `get_env(receiver)` 取得 receiver 暴露的环境；`get_allocator(env)` 查询环境的 allocator。allocator 是 **env 的属性**，不是 receiver 自己的一项资源管理职责。实现说明见 [__env.hpp](https://github.com/NVIDIA/stdexec/blob/main/include/stdexec/__detail/__env.hpp)。
- P2300 §34.5.2 规定 `get_allocator(env)` 调用 `env.query(get_allocator)`，且 `forwarding_query(get_allocator)` 为 true：包装节点应转发这个查询。实现见 [__queries.hpp](https://github.com/NVIDIA/stdexec/blob/main/include/stdexec/__detail/__queries.hpp)。它不是“任何环境都自动带一个默认 allocator”。
- P2300 的 sync-wait-env 提供 `get_scheduler` 和 `get_delegation_scheduler`。NVIDIA 当前实现还提供 start scheduler 等查询，但默认 sync_wait 环境没有 allocator 查询。`sync_wait(sender)` **没有必填 allocator 参数**。见 [__sync_wait.hpp](https://github.com/NVIDIA/stdexec/blob/main/include/stdexec/__detail/__sync_wait.hpp)。
- stdexec 可以用 `write_env` 覆盖子链的环境属性，例如为子链提供 allocator；因此 allocator 不一定始终来自整个服务最外层的 receiver。见 [stdexec 用户指南](https://github.com/NVIDIA/stdexec/blob/main/docs/source/user/index.md)。

## 本库的 Zig API 选择

本库采用固定结构的 Env：**Env.allocator 为可选的 `?std.mem.Allocator = null`，syncWait 仍显式接收 env**。无分配任务可写 `task.syncWait(.{})`；只有执行到需要 allocator 的查询时才要求它存在。缺失时返回 `error.MissingAllocator`，不会隐式使用全局 allocator。

```zig
const env: ex.Env = .{
    .allocator = allocator, // 可省略，默认 null
    .stop_token = source.token(), // 可省略，默认无取消能力
};
const result = try task.syncWait(env);
// 等价的自由函数：
const other = try ex.syncWait(task, env);
```

没有无参 syncWait，也没有隐式 page_allocator；不再区分 syncWaitWithAllocator 与 syncWaitWithEnv。选择 page_allocator 时，应用显式写 `.{ .allocator = std.heap.page_allocator }`。

提供 allocator 不表示每个节点都要分配。已有静态 sender/operation 保持内嵌存储；只有需要动态内存时才使用环境的 allocator。

## 环境的暴露与查询

自定义最终 receiver 必须提供 getEnv：

```zig
pub fn getEnv(self: *@This()) ex.Env {
    return self.env;
}
```

sender 通过环境查询分配器，而不是向 receiver 请求一种独立于环境的 allocator：

```zig
const env = self.receiver.getEnv();
const allocator = env.getAllocator() catch |err| {
    return self.receiver.setError(err);
};
const bytes = allocator.alloc(u8, size) catch |err| {
    return self.receiver.setError(err);
};
```

惰性 sender 的动态分配在 start 后发生，失败走 error 通道。立即执行的 spawn 在调用时分配，分配错误直接返回。connect 仍不分配执行资源且不可失败。自定义 receiver 缺少 getEnv 会在编译期报错；`getEnv` 可以返回空环境 `.{}`。由于 Env 是固定结构，allocator 是否存在为运行时信息，缺失查询在运行时报告，而不是编译期报错。

普通链节点转发整个环境。whenAll 与 withStopToken 仅覆盖取消 token，保留 allocator；调度、then、三种形式及嵌套的 letValue、repeat 等也保留环境。

业务 callback 需要把 allocator 当成输入时，可使用查询 sender：

```zig
const MakeBuffer = struct {
    count: usize,
    pub fn call(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        const bytes = try allocator.alloc(u8, self.count);
        @memset(bytes, 0);
        return bytes;
    }
};

const task = ex.readAllocator().then(MakeBuffer, .{4096});
const buffer = (try task.syncWait(.{ .allocator = allocator })).?[0];
defer allocator.free(buffer);
// buffer 在 syncWait 返回后仍有效。
```

readAllocator 的具体类型为 ex.ReadAllocator，成功输出单个 std.mem.Allocator；缺失时发送 error.MissingAllocator，可通过 uponError/letError 恢复。未启动或被上游错误/停止跳过时不查询。readEnv 返回整个环境，其 allocator 字段可以为 null。同一 sender 可以在不同连接中使用不同环境。

## 分配来源与资源生命周期

Env 借用 allocator，不拥有它，也不是 arena 或资源登记表。分配出的临时资源由相应 operation 释放；转交给最终调用方的拥有型结果由调用方释放。异常和停止路径也必须收尾。根 connection 在 setFinished 才允许回收；临时资源应在所属执行入口退出之前清理，已经发布给下游的结果存储则保持到作用域结束。

syncWait 不统一释放所有分配，也不创建并自动销毁内部 arena；否则返回的 slice/指针可能立即失效。allocator 的底层状态需要活过任务和所有尚未释放的结果。

整个任务使用 arena 时，由调用方提供其 allocator，并在所有结果消费完后释放 arena。并行分支可能同时分配，allocator 必须支持相应的并发访问；普通 ArenaAllocator 不能直接假定线程安全。

upstream 在库内部借用 operation 中的完成 tuple，业务函数仍按声明的参数类型接收值。分配后的 buffer 以 slice 传递即可，复制 slice 不移动底层内存；底层分配仍由指定拥有者保持和释放。内联数组按值传递会复制内容，不能把回调局部数组副本的地址借给异步任务。

## 共享执行与执行上下文

split(allocator, sender) 在连接订阅 receiver 之前创建 shared owner，且订阅方可以有不同环境。共享上游有独立的内部环境，其 allocator 来自 shared owner；不会借用第一个订阅的 allocator，以免共享上游依赖短命的订阅 arena；订阅方可使用空环境。

ThreadPool 和 IoUring context 可以服务多条链，它们的初始化与销毁继续使用各自显式传入的 allocator。任务执行资源和这些长寿命上下文有不同的所有权范围。

## 从必填 allocator 迁移

已显式传入 allocator 的 syncWait 调用不需要改。自定义 sender 的 `getAllocator()` 查询需要处理 `error.MissingAllocator`；直接读取 `env.allocator` 时需要处理 optional。仅需观察环境而不分配的代码可以保留 null。

TCP echo 示例将 allocator 传给 `spawn(sender, token, env)`，分配每个子任务的 operation，
16 KiB buffer 内嵌其中。counting scope 本身无需 allocator，最终 `syncWait(.{})` 也无需分配。
后端 context 初始化仍使用自身的显式 allocator。

`Env.start_scheduler` 是可选的借用调度器句柄；缺省时 syncWait 提供并驱动当前线程的
RunLoop，让异步 counting scope join 回到等待线程。这个默认调度器不会填充 Env.allocator。
详见 [计数作用域](counting_scopes.zh-CN.md)。
