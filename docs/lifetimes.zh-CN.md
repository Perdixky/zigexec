# Operation 结果存储与执行作用域

[English](lifetimes.md) | **简体中文**

普通链式 API 不变：`then(Callback, args)`、`letValue(target, args)`、`syncWait(env)`。底层 sender/receiver 协议改为引用完成值，并区分逻辑完成与允许回收。这是有意加强的生命周期约束，不等同于 P2300 允许在 value/error/stopped completion 内立即销毁 operation 的规则。

## 两个完成时刻

`setValue(*const Values)`、`setError(anyerror)`、`setStopped()` 三者恰好调用一次，发布逻辑结果。此时不能销毁、移动或重建根 connection，不能释放仍被生产者使用的环境与资源。

`ex.connect(sender, &receiver)` 返回 `ex.Connection(SenderType)`。它内嵌原始 `SenderType.Operation` 和一个执行作用域；启动后地址保持稳定。全部执行入口退出后，根 receiver 的可选 `setFinished()` 被调用一次。此时可以回收根 connection，包括在 setFinished 内销毁它。setFinished 调用本身不属于需要保留 operation 的业务完成处理；分发器在调用之后不再访问这个 connection。

没有 setFinished 的手工 receiver 必须通过外部机制保证 execution 已经退出，例如在驱动 RunLoop.run() 返回之后释放 connection；仅观察 setValue 已发生不够。通常应实现 setFinished 来通知拥有者。

`syncWait` 使用根 connection，等待 setFinished 后才返回。成功 tuple 在返回时复制出作用域；内部 pointer/slice 仍不延长其所指对象的生命周期，不能把指向 operation 内部的借用交给 syncWait 的调用者。

## 结果存储

成功值的实体必须位于 operation 自身、同一执行作用域中的上游 operation，或有效期明确覆盖该作用域的外部存储。发布后不可修改该实体；不能把回调局部 tuple 的地址交给 receiver。

```zig
pub const Values = ex.Values(.{i64});
pub const Operation = struct {
    receiver: ex.Receiver(Values),
    output: Values = undefined,
    pub fn start(self: *@This()) void {
        self.output = .{42};
        self.receiver.setValue(&self.output);
    }
};
```

`then` 把业务函数的结果写入自己的 output 槽。`letValue` 与 `upstream()` 借用上游结果，不再复制 input 或构造保存同一 tuple 的 just sender。`continuesOn` 和 `withStopToken` 保存结果指针。`whenAll` 保存各分支结果指针，全部成功后构造一份连续的最终 tuple。

`split` 是独立所有权边界：共享状态保存缓存，每个订阅 operation 保存自己的结果，避免订阅的异步后续依赖已释放的 shared owner。slice、指针仍只做浅复制，库不自动释放用户资源。

业务 callback 的参数类型保持原定义，普通按值 call/callTuple 仍可能发生复制；本次优化保证框架转发不必重复保存整份 payload，不承诺任意业务代码或 sender 构造阶段零复制。生产结果直接写入 output 的优化程度也取决于 Zig 后端。

## 异步入口保护

Env.scope 是库的执行生命周期服务。普通节点原样转发；自定义异步 sender 在发布任务之前取得一个入口，在最后一次 operation 访问之后释放它：

```zig
// 在向另一个线程/后端提交工作之前：
const scope = self.receiver.getEnv().scope;
ex.Scope.acquire(scope);
// submit(self)，失败路径也必须发布 error 并 release(scope)。

// 在对应的完成处理入口中：
const scope = self.receiver.getEnv().scope;
// 保存结果、注销取消回调、通知 receiver，并完成自己的收尾。
self.receiver.setValue(&self.output);
// 所有 operation 访问必须在 release 之前完成。
ex.Scope.release(scope);
```

acquire/release 一一对应，不能在 release 后访问 operation。根 start 已有一个保护，普通同步子链不用每个节点都增加计数。调度器任务、I/O 完成、共享订阅、可能引发完成的取消处理均受保护。自定义异步生产者若不取得入口，会违反协议，Debug/ReleaseSafe 中可能在根作用域空闲时触发断言。

结果、完成状态等写入通过 scope 的 acquire/release 同步，在最后一个入口退出后对 setFinished 可见。scope 本身不分配内存；异步入口使用原子计数，因此存在额外同步成本，不宣称所有负载一定更快。

每次 ex.connect 创建独立根；已有 Env.scope 不会把另一个根隐式变成其拥有者。低层 sender.connect(Receiver) 返回原始 S.Operation，供组合算法使用；手工调用者需自行提供作用域并遵守上述存储规则。

## 循环与复用

repeatEffect 为每一轮提供子作用域，父作用域保持整个循环有效。该轮已经逻辑完成且所有执行入口退出之后才允许下一次 connect/start 覆盖原有 operation 存储。同步十万轮仍由 trampoline 驱动，异步轮次也不递归增长调用栈。跨轮需要的状态应放在循环之外，显式传指针。

## 验证

`tests/lifetime.zig` 覆盖 64 KiB payload 经嵌套 upstream/letValue、调度、取消包装后的地址一致性与 operation 大小；then 结果位于 operation 内；生产者在 setValue 返回后继续使用 operation 时 setFinished/syncWait 必须等待；repeat 不能提前覆盖旧一轮；shared owner 提前释放不影响已调度的订阅结果。

`tests/codegen/receiver_forward.zig` 用真实 Receiver 的函数指针边界检查优化 IR：

```sh
zig build-obj -O ReleaseSafe --dep zigexec \
  -Mroot=tests/codegen/receiver_forward.zig -Mzigexec=src/root.zig \
  -fno-emit-bin -femit-llvm-ir=/tmp/zigexec-receiver-forward.ll
```

在当前 0.17 master / x86_64 LLVM 后端中，64 KiB tuple 通过指针直接转发，forward 函数没有 payload memcpy 或临时数组分配。该检查不代表整张执行图的性能基准。

同一份 `tests/codegen/operation_layout.zig` 对比优化前版本与当前版本，64 KiB `just` 经嵌套 letValue/upstream、continuesOn 和 withStopToken 后，原始组合 operation 的大小从 **721,592 字节降到 197,544 字节**，减少约 72.6%。此数字是 x86_64 上的类型布局，不是吞吐量结果，也不包含根 Connection 的包装。仍保留 sender 描述副本；本次没有消除构造/连接阶段所有复制。

```sh
zig run -O ReleaseSafe --dep zigexec \
  -Mroot=tests/codegen/operation_layout.zig -Mzigexec=src/root.zig
```
