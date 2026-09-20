# P2300 的 operation 构造、地址稳定性与 receiver

核对日期：2026-09-19。依据是
[P2300R10](https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2024/p2300r10.html)
以及 NVIDIA/stdexec 提交
[`957a8331d992cb81dd00091aa5f9a9f2a60ec978`](https://github.com/NVIDIA/stdexec/tree/957a8331d992cb81dd00091aa5f9a9f2a60ec978)。
当前 C++ 草案也作了交叉核对，但不把后续草案或 stdexec 的实现细节等同于 R10。

## 结论与先前分析的纠正

**P2300 的普通适配器不会为了等待地址稳定而把已有子 sender 的 connect 推迟到
start。** 通常在外层 connect 构造 operation 时就完成子 connect；start 才启动
已连接的工作。sender 的惰性执行不意味着 operation 必须惰性构造。

此前把“receiver 指向父 operation → 必须在 start 才 connect → 必须保留 sender”
写成一般因果链不准确。后两步是 zigexec 本次优化前实现的选择。P2300 自身就展示了
包含父 operation 指针、却在构造阶段连接子操作的实现。

同样不能把“operation 只能有 child”或“receiver 不能引用父状态”作为 P2300
的普遍规则。关键是 operation 保存本节点必要状态和已连接的子 operation，
而不是每层冗余保存完整上游 sender 图。

## 1. then 的示例：直接返回上游 connect 的结果

P2300R10 [§1.5.1 then](https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2024/p2300r10.html#example-then)
给出的连接形式是：

```cpp
template <stdexec::receiver R>
auto connect(R r) &&
  -> stdexec::connect_result_t<S, _then_receiver<R, F>> {
  return stdexec::connect(
    (S&&) s_, _then_receiver{(R&&) r, (F&&) f_});
}
```

`_then_receiver<R, F>` 保存下游 receiver 和函数 F。这个教学示例没有额外的
then operation 层，更没有在 operation 里另存一份 S 等待 start。R 与 F 都是
具体模板参数，receiver 的完成方法通过静态类型选择。

这是展示一种实现方式的示例，不是规定所有适配器必须使用相同字段布局。

## 2. 通用规范模型：本节点状态 + 子 operation，构造时连接

R10 [§34.9.1 General](https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2024/p2300r10.html#spec-execution.senders.general)
的 exposition-only 模型是：

```cpp
// 摘录；省略约束、异常说明等。
template<class Sndr, class Rcvr>
struct basic-state {
  Rcvr rcvr;
  state-type<Sndr, Rcvr> state;
};

template<class Sndr, class Rcvr, class Index>
struct basic-receiver {
  basic-state<Sndr, Rcvr>* op;
  // 完成函数静态调用 impls-for<tag>::complete(..., op->state, op->rcvr, ...)
};

template<class Sndr, class Rcvr>
struct basic-operation : basic-state<Sndr, Rcvr> {
  connect-all-result<Sndr, Rcvr> inner-ops;

  basic-operation(Sndr&& sndr, Rcvr&& rcvr)
    : basic-state<Sndr, Rcvr>(std::forward<Sndr>(sndr), std::move(rcvr))
    , inner-ops(connect-all(this, std::forward<Sndr>(sndr), indices-for<Sndr>()))
  {}

  // start 解包 inner-ops，再调用本适配器的 start 定义。
};
```

其中 `connect-all` 遍历 child sender，调用
`connect(child, basic-receiver{op})`；默认 start 则对已经存在的各个 child op
调用 `execution::start`。默认 get-state 提取本节点 data；对 then 来说即函数 F，
不是整棵 sender 图。

因此，receiver 可以引用嵌在父 operation 中的 `basic-state`，同时仍是静态
receiver：**有状态指针与类型擦除是两回事。** `basic-receiver<Sndr,Rcvr,Index>`
的状态类型和完成函数在编译期已知，没有因此变成 `void* + completion vtable`。

## 3. 为什么带内部指针也能在 connect 时完成构造

C++17 的同类型 prvalue 初始化规则允许结果对象直接在最终目标存储中构造。
例如：

```cpp
Op connect(Sender s, Receiver r) {
  return Op(std::move(s), std::move(r));
}

auto op = connect(sender, receiver);
```

这里不需要先构造一个临时 Op，再移动到 `op`。Op 的构造函数可以使用自己的
最终地址，把稳定状态指针传给在成员存储中原地构造的 child operation。
这不是可选的 named return value optimization；`return local_op;` 的 NRVO
不能替代上述 prvalue 构造保证。

R10 §5.2/5.3 以不可复制/移动的 operation 解释该模型。更精确地说，
[R10 §34.8 operation_state 规范](https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2024/p2300r10.html#spec-execution.opstate)
不要求通用 operation_state 类型具备复制/移动能力，并禁止复制/移动连接库提供
sender 所生成的 operation。构造完成后不能再搬动这些带内部地址的 operation，
不能只在 start 后才开始施加这个约束。

R10 的 `emplace-from` 专门解决不可移动 operation 在 optional、variant、tuple
等容器中的原地构造：传入产生 operation prvalue 的工厂，而不是先创建 operation
再 move 进容器。语言规则见
[`[dcl.init.general]`](https://eel.is/c++draft/dcl.init.general)。

最直接的父指针实例是 R10
[§1.5.2 retry](https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2024/p2300r10.html#example-retry)：
`_retry_receiver` 保存 `_retry_op<S,R>*`，operation 构造函数通过捕获 `this`
的连接工厂初始化内部 optional，start 只调用内部 operation 的 start。提案还
明确说明 `_conv` 利用了 C++17 guaranteed copy elision。

该 retry 是教学扩展示例，不是声称 R10 标准化了一个名叫 retry 的算法。它必须
保存 sender，原因是后续失败时需要再次 connect；这与普通 then 的冗余保存不同。

## 4. stdexec 的实际实现

固定提交的
[`__basic_sender.hpp`](https://github.com/NVIDIA/stdexec/blob/957a8331d992cb81dd00091aa5f9a9f2a60ec978/include/stdexec/__detail/__basic_sender.hpp#L300)
中，`__opstate` 的构造函数直接初始化：

```cpp
__state_(__sexpr_impl<__tag_t>::__get_state(...)),
__child_ops_(__apply(__connect_t{}, ..., __state_))
```

它的成员就是 `__state_` 和 `__child_ops_`；start 只分派启动操作。
`__rcvr<Tag,State,Idx>` 持有 `State&`，完成方法静态调用对应的 `__complete`。
[`__then.hpp`](https://github.com/NVIDIA/stdexec/blob/957a8331d992cb81dd00091aa5f9a9f2a60ec978/include/stdexec/__detail/__then.hpp)
复用这个框架，回调作为本节点 data 保存。

这里也有实际编译器适配：该版本 `STDEXEC_IMMOVABLE` 在 GCC 上声明但不定义
move constructor，以绕过编译器问题；不能仅用 `is_move_constructible` 的结果
判断 operation 是否允许移动。其他分支直接删除 move constructor。参见
[`__config.hpp`](https://github.com/NVIDIA/stdexec/blob/957a8331d992cb81dd00091aa5f9a9f2a60ec978/include/stdexec/__detail/__config.hpp#L577)。

不能由普通 then 的静态分派推断整份 stdexec 都没有动态分派。例如此提交的
`__let.hpp` 有虚的 `__start_next` 内部接口；这是实现细节，不改变 receiver 的
具体模板类型，也不是对其实际运行成本的测量。

## 5. 不能提前连接的真正例外：运行时才生成的 sender

R10 [let_value 的规范](https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2024/p2300r10.html#spec-execution.senders.adapt.let)
区分两个阶段：

- 已有的 upstream sender：构造外层 operation 时连接。
- 工厂接到 upstream 完成值后才产生的 sender：完成回调里调用工厂，再 connect
  并原地保存新的 operation，随后 start。

后一种延迟由数据依赖决定，与“等待父 operation 地址稳定”无关。
当代 stdexec 的
[`__let.hpp`](https://github.com/NVIDIA/stdexec/blob/957a8331d992cb81dd00091aa5f9a9f2a60ec978/include/stdexec/__detail/__let.hpp#L303)
同样在构造函数中连接已有 upstream，start 只启动它；后续分支使用自己的
原地存储机制。具体存储复用方式在 R10、当前草案和 stdexec 间已有演进，不能混同。

## 6. 实测构造与布局验证

探针：[benchmarks/p2300_probe.cpp](../benchmarks/p2300_probe.cpp)。在上述 stdexec
提交、GCC `16.2.1 20260810`、x86_64 上运行：

```sh
g++ -std=c++20 -O0 -fno-elide-constructors \
  -I .bench-cache/stdexec/include benchmarks/p2300_probe.cpp \
  -o .bench-cache/p2300-probe
.bench-cache/p2300-probe
```

前提是将对应 stdexec 提交检出到 `.bench-cache/stdexec`；普通基准构建不下载它。
探针首先验证一个显式删除复制/移动的父/子 operation，在父构造时连接并正确
保留状态地址，直到 start 才执行工作。随后实际连接 stdexec 的 16 KiB capture 链：

| 额外空 then 数量 | sender 字节数 | operation 字节数 |
|---:|---:|---:|
| 0 | 16,396 | 16,408 |
| 1 | 16,400 | 16,424 |
| 2 | 16,404 | 16,440 |
| 3 | 16,408 | 16,456 |

每增加一层 operation 只增加 16 字节，不重复 16 KiB capture。这是具体版本、
编译器和 ABI 的布局结果，不是标准保证的字节数，也不是与 Zig TCP echo 的
等价性能比较。`-O0 -fno-elide-constructors` 不会关闭 C++17 强制的 prvalue
原地构造语义；探针没有依赖 NRVO 或优化器去消除错误的状态布局。

## 对 zigexec 的含义

正确的设计约束应是：静态 receiver 类型、必要状态的一份存储、已有 child 在
connect 阶段构造，以及与内部引用相匹配的地址稳定性契约。

Zig 不能直接照搬所有 C++ 不可移动返回值写法，但这不意味着必须在 start 连接。
需要内部地址的节点可以采用显式原地连接，例如以下 API 方向（尚未实现）：

```zig
var op: Operation(Sender, Receiver) = undefined;
connectInto(&op, sender, receiver); // 在最终地址递归构造 state 和 child
op.start();                       // 启动已连接的工作
```

从 connectInto 起保持 op 地址稳定。可以将 `State(R,F)` 与 child 类型分开，
receiver 持有 `*State`，child 类型依赖 receiver，最外层 operation 再聚合
State 和 child，从而避免不必要的泛型类型依赖环。

对没有内部自引用的线性适配器，按值的具体 receiver 也可以继续支持返回 operation
值。两种形式都不应为了以后 start 才 connect 而逐层保留整棵 sender 图。需要
同步更新构造、移动、借用和回收契约，不能把 connect 从 start 挪出来后仍保留
“未 start 的所有 operation 都能随意移动”的假设。


## 本次实现落地

内建 sender 已采用 `Operation(R)` / `connectInto(&child, receiver)`。
公开根为 `Connection(S, R)`，通过 `ex.connectInto(&op, sender, receiver)`
在最终地址初始化；连接后禁止复制/移动。已知子节点在连接阶段构造，
start 只启动工作；工厂依赖输入和 repeat 重连保留相应的延迟时机。
具体 receiver 可引用父状态，这不再要求逐层保留 sender 或使用类型擦除。
旧自定义 sender 的 `Operation` / `connect` 通过显式兼容桥接执行；
内建图不走该擦除路径。低层 API 有意更改，链式组合 API 保持不变。
