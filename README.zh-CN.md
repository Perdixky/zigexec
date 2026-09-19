# zigexec

[English](README.md) | **简体中文**

基于 **Zig 0.17 master** 的 sender/receiver 执行库，参考 [P2300](https://wg21.link/P2300R10) 与 [NVIDIA stdexec](https://github.com/NVIDIA/stdexec)。支持惰性组合、异步串联、并发汇合、线程池、可注册回调的取消、共享 sender，以及真实的 **io_uring 文件 / socket / 定时器 I/O**。

库的协议、公共 API 和后端都不依赖 `std.Io`，无需 libc 或第三方库。目前提供 Linux futex 与 io_uring 后端。验证版本为 `0.17.0-dev.2127+e90365cd5`；master 的后续破坏性变更可能需要适配，不兼容 0.16。

## 构建和测试

```sh
zig build                  # 构建 CPU、文件 I/O 与 TCP echo 示例
zig build test             # 核心、取消、共享状态与通用 I/O 协议测试
zig build test-io           # 真实内核集成测试，要求允许 io_uring
zig build test-errors       # 预期编译失败与诊断检查
zig build test-all          # 运行测试与编译期诊断检查
zig build test-all -Doptimize=ReleaseSafe
zig build run              # 3² + 4² + 5² = 50
zig build run-io            # read 14 bytes: hello io_uring
zig build run-echo -- 9000  # TCP echo，监听 127.0.0.1:9000
zig build test-echo         # 本地 TCP 验证，需要 Python 3
```

集成测试不会用 mock 替代内核，也不会在不允许 io_uring 时静默跳过。测试代码位于 `tests/`，不编入库模块。

## 链式组合

```zig
const std = @import("std");
const ex = @import("zigexec");

const Double = struct {
    pub fn call(_: @This(), value: i64) i64 { return value * 2; }
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const pool = try ex.ThreadPool.init(allocator, 2);
    defer pool.deinit();

    const work = ex.just(.{21}).then(Double, .{}).startsOn(pool.getScheduler());
    const values = (try work.syncWait(.{ .allocator = allocator })) orelse return;
    std.debug.print("{d}\n", .{values[0]}); // 42
}
```

`just(42)` 表示一个值，`just(.{})` 表示空成功，`just(.{a, b})` 表示两个参数。未标注类型的整数/浮点字面量分别转换为 `i64/f64`；可用 `@as` 指定其他类型。

核心是 **链式组合、显式状态、编译期 callback 类型**：

```zig
const task = source.letValue(
    ex.upstream()
        .letValue(SendRequest, .{ config, client })
        .then(Decode, .{})
        .then(AddOffset, .{offset}),
    .{},
);
```

`SendRequest/Decode/AddOffset` 都是带 `pub fn call` 的 struct 类型；args 初始化捕获字段，call 接收上游结果。`then` 处理同步返回值，`letValue(Factory, args)` 调用返回 sender 的工厂，`letValue(body, .{})` 保留并借用上游输入存储并延迟构造整条子链。复杂组合不需要重复整条链来声明返回类型。

构造和 connect 都不执行业务回调。编译期确定图结构、回调和类型，运行时保存 config/client/offset；所以 `letValue(body, .{})` 的 body 不标记 comptime。`upstream()` 绑定最近一层 letValue 并在库内部借用结果存储，业务 callback 参数类型不变；动态 buffer 使用显式分配的内存，以 slice 传递。工厂使用指针 self 可以把 operation 内的捕获字段借给异步 I/O。

反射检查给出包含节点、回调、参数索引和类型的诊断。例如 `just(42).then(Length, .{})` 中 Length 需要字符串时：

```text
zigexec.then: wrong_input.Length.call upstream argument 0: expected []const u8, got i64
```

`letValue` 也接受已构造的 sender：`source.letValue(child, .{})` 在上游成功后连接并启动 child，不把上游值注入 child；需要使用上游值时使用工厂或 `upstream()` 子链。sender/子链形式的第二个参数必须是空的 `.{}`，三种形式均在编译期分派。

完整语义、异步借用限制和迁移说明见 [链式表达式设计](docs/expressions.md)。

## 类型构造器与自动推导

局部变量直接推导：`const work = ex.just(.{21}).then(Double, .{})`。函数返回类型与结构体字段则可使用公开类型构造器：

```zig
fn number(value: i64) ex.Just(.{i64}) {
    return ex.just(.{value});
}

const Work = ex.Just(.{i64})
    .Then(Double)
    .StartsOn(ex.ThreadPool.Scheduler);

const Io = ex.io.For(*ex.IoUring);
// 回调可直接返回 Io.ReadSome；等价于 ex.io.ReadSome(*ex.IoUring)。
```

类型级 `.Then/.LetValue/.StartsOn/...` 与值级 `.then/.letValue/.startsOn/...` 对应，返回完全相同的具体 sender 类型。`WhenAll(.{A, B})` 接收 sender 类型列表；`Values(.{i64, bool})` 构造成功 tuple 类型。

泛型 callback 的返回类型由上游参数特化。普通函数可通过 `Fn` 保留编译期函数身份：

```zig
fn twice(value: anytype) @TypeOf(value) { return value * 2; }
const work = ex.just(.{@as(u16, 21)}).then(ex.Fn(twice), .{});
// 下游值自动推导为 u16。
```

`meta.ReturnOf(factory, .{参数类型...})` 查询泛型工厂的返回类型，`meta.ValuesOf/ValueOf/OperationOf/WaitResult` 查询 sender 的关联类型。这些 helper 不运行任务、不分配内存，也不进行 sender 类型擦除。

Zig 仍要求函数边界声明返回类型，库不能提供任意函数体的 `auto` 返回推导。详见 [类型 API 设计与示例](docs/types.md)。

## 常用 API

| 功能 | 接口 |
| --- | --- |
| 原始 sender | `just`、`justError(Values, err)`、`justStopped(Values)`、`readEnv`、`readAllocator` |
| 值变换 | `.then(Callback, args)` |
| 普通值恢复 | `.uponError(Callback, args)`、`.uponStopped(Callback, args)` |
| 异步工厂/恢复 | `.letValue(Factory, args)`、`.letError(Factory, args)`、`.letStopped(Factory, args)` |
| 子链/顺序执行 | `.letValue(body, .{})` 绑定 `upstream()` 子链；`.letValue(child, .{})` 顺序启动已有 sender |
| 重复执行 | `.repeatEffect()`、`.repeatEffectUntil()` |
| 并发汇合 | `whenAll(.{a, b, ...})` |
| 逐索引执行 | `.bulk(count, Callback, args)` |
| 执行上下文 | `ThreadPool`、`RunLoop`、`InlineScheduler`、`IoUring` |
| 调度 | `scheduler.schedule()`、`.startsOn(scheduler)`、`.continuesOn(scheduler)` |
| 取消 | `StopSource`、`StopToken`、`StopCallback`、`.withStopToken(token)` |
| 共享计算 | `.split(allocator)`，owner 的 `.sender()`、`.clone()`、`.deinit()`、`.requestStop()` |
| 消费 | `.syncWait(env)`、`syncWait(sender, env)`、`connect/start` |

`syncWait` 返回 `anyerror!?Sender.Values`：成功为 tuple，错误使用 `try/catch`，stopped 为 `null`。空 tuple 与 stopped 不同，`error.Canceled` 不自动转换成 stopped。恢复算法须保持原 sender 的成功 tuple 类型；多值恢复用 `letError/letStopped`。

`whenAll` 等待所有分支，成功时按输入顺序拼接，失败时请求兄弟任务停止并等它们收尾；最终 error 优先于 stopped，报告最先观察到的错误。分支调度到线程池才产生并行，`bulk` 本身是顺序执行。

`startsOn` 移动上游的启动位置；`continuesOn` 移动下游完成通知。调度失败/取消可以替换上游的完成。`syncWait` 阻塞当前线程，不自动驱动外部 run loop；不要在 reactor 内阻塞等待自身 I/O，也不要耗尽池线程等待同一池的后续工作。

## 执行 allocator

allocator 是 Env 的可选属性，默认 null；不查询 allocator 的任务可以使用 `task.syncWait(.{})`。receiver 通过 getEnv 暴露执行环境，需要分配时显式配置：

```zig
const result = try task.syncWait(.{ .allocator = allocator });
// 或者同时配置取消：
const result_with_env = try task.syncWait(.{
    .allocator = allocator,
    .stop_token = source.token(),
});
```

sender 在 start 中使用 `receiver.getEnv().getAllocator()` 并处理错误，业务链可以通过 `readAllocator()` 查询。环境穿过调度、并发和取消包装继续传递；查询缺失返回 `error.MissingAllocator`，分配失败走 error 通道。没有默认的全局分配器；静态节点无需堆分配。IoUring、ThreadPool 初始化与 split 创建 owner 仍显式接收 allocator。

allocator 由调用方借出，不会在 syncWait 返回时自动释放它分配的结果；资源由相应拥有者清理。共享上游使用 shared owner 的 allocator，避免依赖某个短命订阅。具体边界与示例见 [allocator 设计](docs/allocators.md)。

## 完整取消回调

```zig
var source: ex.StopSource = .{};
defer source.deinit();
var registration: ex.StopCallback = .{};
registration.init(source.token(), &state, onStop);
defer registration.deinit();
_ = source.requestStop();
```

注册和解除注册线程安全。已经请求停止时 `init` 同步调用回调；`deinit` 等待其他线程正在执行的回调，并支持回调注销/销毁自身。source 与已注册节点保持地址稳定，source 必须活到所有注册解除且 `requestStop` 返回。详见 [取消协议](docs/cancellation.md)。

取消仍是协作式的：`just` 无条件完成，普通 `then` 不被抢占；长 CPU 任务可通过 `readEnv` 获取 token。io_uring 则用回调唤醒 reactor，提交内核取消请求，无需任务主动轮询。

## 共享 sender

```zig
var shared = try ex.just(.{21}).then(Double, .{}).startsOn(cpu).split(allocator);
defer shared.deinit();

const values = (try ex.whenAll(.{
    shared.sender(),
    shared.sender().then(Double, .{}),
}).syncWait(.{ .allocator = allocator })).?; // .{ 42, 84 }，上游只运行一次
```

`split` 分配共享状态但不立即运行。首次订阅启动一次上游，后续订阅共享或重放缓存的 value/error/stopped。owner 不能按普通值复制后分别释放；需要额外 owner 时显式 `clone()`。`.sender()` 是借用视图，owner 至少保持到 operation 启动；启动后的订阅和上游持有自己的引用。任一订阅的取消请求会请求停止整个共享上游。详见 [共享状态与所有权](docs/shared.md)。

## io_uring

```zig
const context = try ex.IoUring.init(allocator, .{ .entries = 64 });
defer context.deinit();

const n = (try ex.io.readSome(context, fd, buffer, 0).syncWait(.{ .allocator = allocator })).?[0];
_ = n;
```

`ex.io` 是独立于具体后端的 sender 层，context 协议可接入其他实现。当前 io_uring 后端支持：

- 文件：`openAt`、`readSome`、`writeSome`、`fsync`、`close`。
- Socket：`accept`、`connect`、`recv`、`send`、处理短写的 `sendAll`。
- 定时器：`sleepFor(context, nanoseconds)`；使用单调时钟。
- 调度：`context.getScheduler().schedule()`。

读写可能短传输；`readSome/recv` 返回 0 表示 EOF。文件 offset 显式传入，`io.current_offset` 表示使用当前偏移。buffer、path、socket address 和 fd 必须保持有效到完成；成功取得的 fd 由调用方关闭。对已取得 fd 的错误路径优先使用明确的 `defer` 清理，完整示例见 [io_uring 示例](examples/io_uring.zig)。

context 自带一个 reactor 线程。I/O 完成后的 continuation 默认在该线程运行；CPU 密集任务使用 `.continuesOn(pool.getScheduler())` 转出。`shutdown()` 关闭新提交并取消剩余请求；`deinit()` 等待收尾并释放。取消会等原请求和取消请求的 CQE，避免 buffer 过早释放及地址复用问题。

更多生命周期、SQ 背压、内核要求和错误行为见 [io_uring 后端](docs/io_uring.md)。

## TCP echo 示例

```sh
zig build run-echo -- 9000
# 另一个终端连接，输入内容即可收到回显：
nc 127.0.0.1 9000
```

实现见 [examples/tcp_echo.zig](examples/tcp_echo.zig)。默认端口为 9000，传 0 由内核选择空闲端口；可用 `--once` 在一个连接结束后退出，例如 `zig build run-echo -- 9000 --once`。

这是逐个处理连接的小示例：整个服务是一条 `accept → letValue(连接内 recv/sendAll/repeatEffect 与清理) → repeatEffectUntil` 链，main 最后只调用一次 syncWait。连接内和接受连接的循环都由 zigexec 驱动，callback 内没有阻塞等待。buffer 从执行环境的 allocator 分配，在 EOF/错误/停止后释放，客户端 socket 始终关闭。

`sendAll` 内部用 `repeatEffectUntil` 处理短写；使用 MSG.NOSIGNAL 避免断开的客户端通过 SIGPIPE 终止服务。`zig build test-echo` 验证空连接、1 MiB 二进制/分段输入、半关闭、连接重置和后续重连。循环算法语义见 [重复执行](docs/repeat.md)。

## 结构与扩展

```text
src/
  execution/           # receiver、environment、connect、fluent facade
  callbacks/           # 显式捕获初始化、编译期函数适配
  expressions/         # deferred 子链与词法输入绑定
  cancellation/        # source、token、callback
  senders/             # 每种基础 sender 独立文件
  algorithms/          # 每种组合算法独立文件；共用模板放 detail/
  schedulers/          # inline、run loop、线程池
  consumers/           # syncWait
  io/                  # 后端无关的请求描述与 I/O sender
  backends/io_uring/   # reactor、请求状态、SQE 编码、CQE 解码
  detail/              # 内部队列、同步、生命周期辅助
  types.zig / meta.zig # 公开类型构造器与类型查询
  root.zig             # 公共入口
tests/                # 单元、内核集成及 compile_fail 诊断测试
examples/             # CPU、io_uring 文件流水线与 TCP echo
```

自定义 sender 提供 `Values`、`Operation`、`connect(Receiver(Values)) Operation`；operation 提供 `start(*Self) void`。`ex.asSender(custom)` 提供链式方法。每个 operation 只启动一次，启动后保持地址稳定，并恰好发送一次完成。`setValue` 接收 `*const Values`，发布的结果须来自稳定存储。`ex.connect` 返回 `Connection(S)`；根 receiver 只能在 `setFinished` 中回收 connection。自定义异步 sender 必须在提交前 acquire Env.scope，在收尾后 release。详见 [生命周期协议](docs/lifetimes.md)。

自定义 scheduler 的 `schedule()` 返回空成功 tuple 的 sender。I/O context 的请求协议见 [架构与 stdexec 对应](docs/design.md)。

## 作为依赖

使用方 `build.zig.zon` 的 `.dependencies`：

```zig
.zigexec = .{ .path = "../zigexec" },
```

使用方 `build.zig`：

```zig
const dep = b.dependency("zigexec", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zigexec", dep.module("zigexec"));
```

当前仍不是完整的 C++26 标准实现：每个 sender 只有一个成功 tuple 类型，错误统一为 `anyerror`；尚无 `on` 环境恢复、`whenAny`、`async_scope`、GPU 与协程互操作。共享结果使用 Zig 值复制，没有隐式 RAII 或深拷贝。跨平台后端、性能基准和 sanitizer 验证尚待补充。

## 许可证

本项目使用 [Mozilla Public License 2.0](LICENSE)。
