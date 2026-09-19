# 类型构造器与推导

首选用 [链式子表达式](expressions.md) 直接构造复杂流水线，由库推导整张图。显式的返回类型通常只出现在业务 callback 中，每个工厂直接返回一个 sender：

```zig
const Duplicate = struct {
    pub fn call(_: @This(), value: anytype) ex.Just(.{ @TypeOf(value), bool }) {
        return ex.just(.{ value, true });
    }
};
const task = ex.just(@as(u16, 42)).letValue(
    ex.upstream().letValue(Duplicate, .{}),
    .{},
);
// task.Values 为 tuple { u16, bool }。
```

无需通过假造 context、buffer、fd 或 undefined 表达式命名类型。类型构造器保留静态 operation 布局，不进行动态 sender 擦除或额外堆分配。

## 命名类型与类型级组合

```zig
fn number(value: i64) ex.Just(.{i64}) {
    return ex.just(value);
}

const Double = struct {
    pub fn call(_: @This(), value: i64) i64 { return value * 2; }
};
const Work = ex.Just(.{i64}).Then(Double).StartsOn(ex.ThreadPool.Scheduler);
```

小写方法构造值，大写方法构造对应类型。`ex.Then(S, Callback)` 与 `S.Then(Callback)` 等价，Callback 是 struct 类型；普通函数使用 `ex.Fn(function)`。

| 构造器 | 参数 |
| --- | --- |
| `Values(.{i64, bool})` | 成功/参数 tuple 的类型列表 |
| `Just(.{i64})`、`JustError(.{i64})`、`JustStopped(.{i64})` | 成功值的类型列表；空成功用 `.{}` |
| `Immediate(ValueTuple)` | 已有完整 tuple 类型时的同步 sender 类型 |
| `ReadEnv`、`ReadAllocator` | 无参数的具体类型，不需要括号 |
| `Then(S,F)`、`UponError(S,F)`、`UponStopped(S,F)` | 输入 sender 类型、callback 类型 |
| `LetValue(S,Target)` | 输入 sender 类型；Target 为工厂类型、sender 类型或 deferred 子表达式类型 |
| `LetError(S,F)`、`LetStopped(S,F)` | 输入 sender 类型、恢复工厂 callback 类型 |
| `Bulk(S,F)` | 输入 sender 类型、callback 类型；count 不进入类型 |
| `RepeatEffect(S)`、`RepeatEffectUntil(S)` | 重复执行空成功 effect，或重复到 bool 为 true |
| `WhenAll(.{A,B})` | sender 类型列表 |
| `WithStopToken(S)` | 输入 sender 类型 |
| `Schedule(Scheduler)` | scheduler 类型 |
| `StartsOn(Scheduler,S)`、`ContinuesOn(S,Scheduler)` | scheduler 和 sender 类型 |
| `Shared(S)` | split 的 owner 类型；运行时由 split 显式分配 |
| `Connection(S)` | 公开 ex.connect 返回的根连接，包含原始 S.Operation 与执行作用域 |
| `Sender(Implementation)` | 为自定义实现添加 fluent facade 的类型 |
| `Fn(function)` | 已知普通/泛型函数的无状态 callback 类型 |
| `Bind(function, .{PrefixTypes...})` | 已知函数及绑定前置参数的类型列表 |

`JustError/JustStopped` 指定可能成功时的值类型，不是错误类型。当前三种 immediate sender 共享一个完成 union，因此相同成功 tuple 的类型相同。

`Just(.{i64})` 同时匹配 `just(21)` 和 `just(.{21})`。未标注整数字面量物化为 i64；需要 u16 时用 `just(@as(u16, 21))`。`Values` 是 `@Tuple` 的便利构造器。

`ThreadPool.Scheduler` 和 `RunLoop.Scheduler` 提供明确的调度器类型名。`asSender` 幂等；`Schedule(Scheduler)` 同时匹配 `scheduler.schedule()` 和 `ex.schedule(scheduler)`。

## I/O 类型与后端特化

```zig
const Io = ex.io.For(*ex.IoUring);

const ReadBack = struct {
    context: *ex.IoUring,
    fd: i32,
    buffer: []u8,
    pub fn call(self: @This(), written: usize) Io.ReadSome {
        return Io.readSome(self.context, self.fd, self.buffer[0..written], 0);
    }
};
```

不定义命名空间时，同一返回类型为 `ex.io.ReadSome(*ex.IoUring)`。

公开类型有 `ReadSome/WriteSome/Recv/Send/SendAll/SleepFor/OpenAt/Close/Fsync/Accept/Connect/Schedule(ContextPointer)`，参数是 context 指针类型。`io.For(ContextPointer)` 固定该参数后提供同名类型和小写构造函数；`Io.Schedule` 用于 context scheduler 的返回类型。

这些都是具体操作类型。输出同为 usize 的不同 sender 可以具有不同 operation 布局，不能只凭输出类型互换。

## 根据上游特化

`then` 与工厂形式的 `letValue` 使用上游 Values，error 恢复使用单个 anyerror，stopped 恢复没有参数，bulk 在上游参数前增加 usize 索引。库用这些类型特化泛型 `call` 或 `callTuple`，不执行工厂函数体。

```zig
fn twice(value: anytype) @TypeOf(value) { return value * 2; }
const task = ex.just(@as(u16, 21)).then(ex.Fn(twice), .{});
// 输出值为 u16。
```

回调类型、图结构、反射校验和结果类型都在编译期确定。运行时捕获的字段值不进入类型。返回类型必须能够由函数身份和参数类型决定，不能依赖普通运行时字段的具体值。

`call` 的 self 可按值或指针传递，指针 self 指向 operation 内的持久存储；不需要把实际状态变成 comptime。复杂链直接放进 `letValue`，无需为整条链写另一个手工类型表达式。

## 可选的前置参数绑定

显式 callback 字段是常规捕获方式。已有普通函数如果需要绑定前置参数，也可使用低层 `Bind/bind`：

```zig
fn multiply(factor: i64, value: i64) i64 { return factor * value; }
const callback = ex.bind(multiply, .{2});
const task = ex.just(21).then(@TypeOf(callback), callback);
```

参数按 `prefix ++ upstream_values` 拼接。function 必须编译期已知，prefix 按值保存运行时参数。绑定指针不会延长指向数据的生命周期；需要具体 comptime 参数值的任意部分求值，应先用用户 wrapper 明确特化。

## 查询关联类型

| 查询 | 结果 |
| --- | --- |
| `meta.ValuesOf(S)` | 完整成功 tuple 类型 |
| `meta.ValueOf(S)` | 唯一成功值类型；零个或多个值时报错 |
| `meta.OperationOf(S)` | 原始 S.Operation，供内部 sender.connect 使用；公开 ex.connect 返回 Connection(S) |
| `meta.WaitResult(S)` | `anyerror!?S.Values` |
| `meta.CallResult(Callback, ArgumentTuple)` | callback 在给定参数 tuple 下的结果类型 |
| `meta.ReturnOf(function, .{ArgumentTypes...})` | 特化已知函数/工厂并查询返回类型 |

```zig
const Read = ex.meta.ReturnOf(ex.io.readSome, .{ *ex.IoUring, i32, []u8, u64 });
// 等价于 ex.io.ReadSome(*ex.IoUring)。
```

deferred body 没有独立的 Values；可在知道输入 tuple 后通过 `@TypeOf(body).Bound(InputValues)` 查询具体 sender 类型。通常直接组合 `source.letValue(body, .{})` 即可。

查询不执行函数体。需要具体 comptime 参数值才能特化的工厂不能只用参数类型查询；先固定该参数或使用显式类型构造器。

Zig 的函数边界仍需声明返回类型，库不能提供任意函数的 auto 返回推导。表达式组合将这一负担缩小到单个 callback 的结果，而不是整张执行图。
