#include <stdexec/execution.hpp>
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <type_traits>
#include <utility>

// Demonstrate constructor-time child connection with stable state references.
struct State { int value = 0; };
struct Receiver { State* state; void set_value() { state->value = 42; } };
struct Child {
  Receiver receiver;
  explicit Child(Receiver r): receiver(r) {}
  Child(const Child&) = delete;
  Child(Child&&) = delete;
  void start() { receiver.set_value(); }
};
Child connect_child(Receiver r) { return Child(r); }
struct Parent {
  State state;
  Child child;
  Parent(): state{}, child(connect_child(Receiver{&state})) {}
  Parent(const Parent&) = delete;
  Parent(Parent&&) = delete;
  void start() { assert(child.receiver.state == &state); child.start(); }
};
Parent connect_parent() { return Parent(); }

struct Big {
  unsigned char bytes[16384]{};
  int operator()(int x) noexcept { return x + bytes[0]; }
};
struct Result {
  using receiver_concept = stdexec::receiver_tag;
  int* result;
  void set_value(int value) noexcept { *result = value; }
  void set_error(std::exception_ptr) noexcept { std::abort(); }
  void set_stopped() noexcept { std::abort(); }
  auto get_env() const noexcept { return stdexec::env<>(); }
};
template<int N> auto chain() {
  if constexpr (N == 0)
    return stdexec::just(42) | stdexec::then(Big{});
  else
    return chain<N - 1>() | stdexec::then([](int x) noexcept { return x; });
}
template<int N> void check() {
  int value = 0;
  auto sender = chain<N>();
  auto operation = stdexec::connect(std::move(sender), Result{&value});
  // stdexec declares an undefined move constructor on GCC as a workaround.
  // This probe never moves the operation.
  static_assert(!std::is_copy_constructible_v<decltype(operation)>);
  assert(value == 0);
  stdexec::start(operation);
  assert(value == 42);
  std::printf("extra_then=%d sender=%zu operation=%zu\n", N, sizeof(sender), sizeof(operation));
}
int main() {
  static_assert(!std::is_move_constructible_v<Parent>);
  static_assert(!std::is_move_constructible_v<Child>);
  auto parent = connect_parent();
  assert(parent.child.receiver.state == &parent.state);
  assert(parent.state.value == 0);
  parent.start();
  assert(parent.state.value == 42);
  std::puts("constructor-time connection with immovable parent/child: passed");
  check<0>(); check<1>(); check<2>(); check<3>();
}
