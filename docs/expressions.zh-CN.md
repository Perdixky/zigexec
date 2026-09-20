# 链式表达式、显式状态与编译期回调

[English](expressions.md) | **简体中文**

公开 API 以 callback **类型**和显式捕获状态为中心：

```zig
const task = source.letValue(
    ex.upstream()
        .letValue(SendRequest, .{ config, client })
        .then(Decode, .{})
        .then(AddOffset, .{offset}),
    .{},
);
```

`SendRequest/Decode/AddOffset` 是带 `pub fn call` 的 struct 类型，不是 struct 实例。`args` 初始化 struct 字段；上游值是 `call` 的后续参数。每个手写工厂只需声明它直接返回的 sender 类型。整个表达式的类型由库推导，不必在另一个返回类型表达式中重复链条。

## 核心操作与三种 continuation

| 接口 | 语义 |
| --- | --- |
| `ex.upstream()` | 最近一层 `letValue` 的成功值；尚未绑定输入的子链起点 |
| `.then(Callback, args)` | 初始化捕获，执行同步 `call`，把结果传给下一步 |
| `.letValue(Factory, args)` | 初始化捕获，执行返回 sender 的工厂，等待子 sender 完成 |
| `.letValue(body, .{})` | 借用上游 operation 的成功值，绑定并启动 `upstream()` 子链 |
| `.letValue(child, .{})` | 上游成功后连接并启动已有 sender，不向它注入上游值 |

实际签名：

```zig
then(self, comptime Callback: type, args: anytype)
letValue(self, target: anytype, args: anytype)
```

Zig 不支持同名方法按参数个数重载，因此统一使用两个参数，与 `then` 一致。target 为工厂 **类型**时隐含 comptime，args 初始化其字段；target 为 sender 或子链 **值**时保留运行时状态，args 必须为 `.{}`。类型反射在编译期选择实现，没有运行时分派或类型擦除。传入工厂实例、sender 类型、无效 target 或给子链额外传捕获都会产生明确的编译期错误。

已有 sender 的构造表达式立即求值，其 operation 在外层连接时构造，start 仍等待上游成功；依赖输入的 deferred 表达式在输入到达后绑定和连接。若 sender 构造本身需要在上游成功后才执行，请用工厂。上游 error/stopped 时三种形式均跳过 continuation 的执行并转发原完成；子 sender 的 value/error/stopped 则传到下游。

`body` **不是 comptime 参数**：其中可能包含运行时的 config、client、offset。编译期确定的是 `@TypeOf(body)`、图结构、回调身份、输入/输出类型和 operation 布局。捕获的字段值在运行时保存；反射遍历和协议检查全部在编译期完成。

表达式本身不是已绑定的 sender，不能直接 `connect/syncWait`。接到 `source.letValue(body, .{})` 后才具备具体的 Values 和 Operation。嵌套作用域中，内层 `upstream()` 只绑定内层 `letValue` 的输入；内层完成结果再交给外层后续节点。

## struct 捕获与业务代码

```zig
const AddOffset = struct {
    offset: i64,
    pub fn call(self: @This(), value: i64) i64 {
        return self.offset + value;
    }
};

const Io = ex.io.For(*ex.IoUring);
const SendRequest = struct {
    context: *ex.IoUring,
    socket: i32,
    pub fn call(self: @This(), request: []const u8) Io.Send {
        // 同步校验、准备可以在这里完成；返回一个 sender 即可。
        return Io.send(self.context, self.socket, request, 0);
    }
};
```

两种初始化方式：

```zig
.then(AddOffset, .{offset})             // 按字段声明顺序
.then(AddOffset, .{ .offset = offset }) // 按字段名称
```

非空位置元组必须提供全部字段；命名初始化支持默认字段，`.{}`使用全部默认值。也允许传入已构造的 Callback 值作为 args。字段类型由 Callback 决定，字面量自然转换到该字段的类型。捕获按值复制，指针只复制地址；共享可变状态显式通过指针表达。

与“给裸函数绑定前置参数”不同，struct 的显式参数进入 self：概念上的调用顺序是 `Callback{captures}.call(upstream...)`。`call` 可使用 `self: @This()`、`*@This()` 或 `*const @This()`。指针 self 指向 **operation 内的 callback 存储**，不是临时副本。

`then` 返回 `void/!void` 时成功值为空，返回 `T/!T` 时成功值为单个 T。`letValue` 的工厂返回 sender 或 `!Sender`；后续类型来自该 sender 的 Values。返回错误进入 error 通道，子 sender 的 stopped 保持为 stopped。

`uponError/uponStopped/letError/letStopped/bulk` 同样接收 callback 类型和显式状态：

```zig
sender.uponError(Recover, .{state})
sender.letError(Retry, .{client})
sender.bulk(count, Fill, .{buffer})
```

恢复回调仍须保持原成功 tuple 的类型。error 回调接收 `anyerror`，stopped 回调无输入，bulk 接收 `usize` 索引再接上游值。这些操作以及 `startsOn/continuesOn/withStopToken` 都能用于 deferred 子链。`.repeat()` 重复空成功 effect，`.repeatUntil()` 重复到 effect 返回 true；同样支持 deferred 子链，详见 [重复执行](repeat.zh-CN.md)。

## 存储与异步借用

构造表达式只保存状态；`connect` 不执行业务逻辑。`start` 后，上游把成功 tuple 存入自己的 operation；scope 借用其地址，构造并连接子链，不再重复保存输入。operation 从连接时起必须保持地址稳定。完成通知中即可回收根 connection；拥有者也可以继续保留 child，以延长借用结果的存储寿命。生产者通知后不得再访问自身。见 [生命周期协议](lifetimes.zh-CN.md)。

`upstream()` 在框架内部按引用转发成功 tuple，业务 callback 仍使用其声明的参数类型。跨异步使用的动态 buffer 可以通过 allocator 显式分配，再以 slice 传递。slice 的复制只复制地址和长度，底层分配地址不变；其拥有者负责保持内存有效并最终释放。

```zig
const Write = struct {
    context: *ex.IoUring,
    file: i32,
    pub fn call(self: @This(), buffer: []const u8) Io.WriteSome {
        return Io.writeSome(self.context, self.file, buffer, 0);
    }
};

const buffer = try allocator.alloc(u8, 4096);
defer allocator.free(buffer);
@memset(buffer, 0);
const task = ex.just(buffer).letValue(
    ex.upstream().letValue(Write, .{ context, file }),
    .{},
);
_ = try task.syncWait(.{ .allocator = allocator });
```

拥有者、分配来源和借用是分别明确的：统一 allocator 不等于统一自动释放；`letValue` 不把用户 buffer 的所有权隐式接管。内联数组仍按值复制，需要异步访问时不可借用回调栈上副本的地址。

回调自身的捕获字段也可以借给异步子任务：

```zig
const Read = struct {
    context: *ex.IoUring,
    file: i32,
    buffer: [4096]u8 = undefined,
    pub fn call(self: *@This()) Io.ReadSome {
        return Io.readSome(self.context, self.file, &self.buffer, 0);
    }
};
```

这里必须使用指针 self，不能借用按值 self 的局部副本。工厂函数自己的栈局部数组也不能借给异步 sender。普通切片/外部指针的复制不会延长它指向的外部资源的生命周期。

scope 内部借用不得逃逸到 operation 销毁之后。特别是 `syncWait` 返回时其 operation 已经结束，不应返回指向 scope/callback 内部的 slice 或指针供调用方继续使用。应在链内消费这些引用，或显式把结果复制到外部存储。库不隐式调用用户值的 `deinit`、深拷贝资源或自动关闭 fd。

## 泛型与普通函数适配

callback 可使用 `anytype`，库根据上游参数特化 `call`。也可提供 `callTuple(self, args: anytype)` 接收完整成功 tuple；若两个方法都有，优先 callTuple。业务函数仍声明自身返回类型。

无需捕获状态的已有普通函数可通过 `Fn` 适配，保留编译期函数身份：

```zig
fn twice(n: anytype) @TypeOf(n) { return n * 2; }
const task = ex.just(@as(u16, 21)).then(ex.Fn(twice), .{});
// 输出仍为 u16；没有运行时函数指针。
```

运行时函数指针可以作为用户 callback 的显式字段，由它的 `call` 调用。只有确实需要动态选择行为时才需要这样做。

## 编译期错误

对已经绑定的 sender，在组合时检查；对 deferred 子链，依赖输入的检查在附着到 `letValue` 时发生。未执行任务也会报错。

```zig
const Length = struct {
    pub fn call(_: @This(), text: []const u8) usize { return text.len; }
};
const bad = ex.just(42).then(Length, .{});
```

首条诊断包含节点、callback、参数索引及两侧类型：

```text
error: zigexec.then: wrong_input.Length.call upstream argument 0: expected []const u8, got i64
```

专门检查 callback 方法/self、参数数量、常见不兼容输入类型、捕获字段的名称/数量/必填项/类型，以及工厂返回的 sender 协议。泛型方法体、依赖具体值的转换及复杂结构转换由 Zig 自身继续检查；库不试图重新实现完整的语言类型系统。

`zig build test-errors` 验证预期编译失败的诊断，`zig build test-all` 同时包含这些检查。测试只匹配稳定的关键诊断，不依赖编译器调用栈的具体行号。

## 旧 API 迁移

| 原写法 | 新写法 |
| --- | --- |
| `.then(AddOffset{ .offset = n })` | `.then(AddOffset, .{n})` |
| `.then(double)` | `.then(ex.Fn(double), .{})` |
| `.letCall(Factory, args)` | `.letValue(Factory, args)` |
| `.letValue(body)` | `.letValue(body, .{})` |
| 手写 callback 返回整条链 | `.letValue(ex.upstream().letValue(Factory, args).then(Transform, .{}), .{})` |
| `LetCall(S, Factory)` | `LetValue(S, Factory)` |

旧名称与单参数接口不保留别名。`LetValue(S, Target)` 的 Target 可为工厂、已有 sender 或 deferred 子链的类型；三种形式均匹配实际构造出的具体类型。见 [类型 API](types.zh-CN.md)。

## 执行环境的 allocator

allocator 属于 Env；最终 receiver 通过 getEnv 暴露该环境，整条普通链转发它。allocator 可以省略；sender 在 start 中通过 `receiver.getEnv().getAllocator()` 查询并处理错误，业务代码可使用 `readAllocator()`，缺失时发送 error.MissingAllocator；由 `task.syncWait(.{ .allocator = allocator })` 或自定义 receiver 配置。它统一分配来源，不自动把值提升到堆上或替用户释放拥有型结果。详见 [allocator 与所有权](allocators.zh-CN.md)。
