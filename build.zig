const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.addModule("zigexec", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zigexec", .module = mod }},
    }) });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run the sender/receiver tests").dependOn(&run_tests.step);

    const error_tests = b.step("test-errors", "Verify compile-time API diagnostics");
    const diagnostic_cases = .{
        .{ "when_any_empty", "zigexec.whenAny: requires at least one sender" },
        .{ "when_any_container", "zigexec.whenAny: expected a tuple or named struct of senders" },
        .{ "when_any_sender", "zigexec.whenAny: i64 must return a sender or !sender (Values, Operation.start, connect); got i64" },
        .{ "when_all_arity", "expects 1 upstream value(s), but upstream provides 2" },
        .{ "spawn_errors", "zigexec.spawn: sender may complete with error; handle errors with an infallible uponError or letError before spawning" },
        .{ "spawn_fallible_handler", "zigexec.spawn: sender may complete with error; handle errors with an infallible uponError or letError before spawning" },
        .{ "spawn_schedule_error", "zigexec.spawn: sender may complete with error; handle errors with an infallible uponError or letError before spawning" },
        .{ "spawn_values", "zigexec.spawn: task must complete with no values; consume results with then first" },
        .{ "scope_run_values", "zigexec.runInScope: producer must complete with no values" },
        .{ "wrong_input", "upstream argument 0: expected []const u8, got i64" },
        .{ "deferred_input", "upstream argument 0: expected []const u8, got i64" },
        .{ "wrong_arity", "expects 2 upstream value(s), but upstream provides 1" },
        .{ "missing_call", "must declare pub fn call(self, ...) or callTuple(self, args)" },
        .{ "wrong_self", "self must be Callback, *Callback, or *const Callback" },
        .{ "capture_type", ".offset: expected i64, got bool" },
        .{ "capture_missing", "missing field offset" },
        .{ "capture_unknown", "has no field typo" },
        .{ "capture_count", "positional state must supply every field; use a named initializer for defaults" },
        .{ "not_sender", "must return a sender or !sender (Values, Operation.start, connect); got i64" },
        .{ "not_body", "zigexec.letValue: expected a sender factory type, a sender value, or an upstream() subchain" },
        .{ "sender_captures", "zigexec.letValue: sender/subchain operands require .{} as args; captures belong to factory callbacks" },
        .{ "expression_captures", "zigexec.letValue: sender/subchain operands require .{} as args; captures belong to factory callbacks" },
        .{ "sender_invalid_args", "zigexec.letValue: sender/subchain operands require .{} as args; captures belong to factory callbacks" },
        .{ "factory_instance", "zigexec.letValue: pass the factory type as the first argument and its captures as the second" },
        .{ "sender_type", "zigexec.letValue: pass a constructed sender/subchain value; only a factory callback is passed as a type" },
        .{ "repeat_values", "zigexec.repeat: expected an empty completion tuple; use then to discard values" },
        .{ "repeat_condition", "zigexec.repeatUntil: expected one bool completion value; true finishes, false repeats" },
        .{ "receiver_env", "zigexec.receiver: provide getEnv() returning an Env" },
        .{ "receiver_value", "zigexec.receiver: setValue must accept *const Values; copy values.* only when retaining an owned result" },
    };
    inline for (diagnostic_cases) |case| {
        const check = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("tests/compile_fail/" ++ case[0] ++ ".zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zigexec", .module = mod }},
        }) });
        check.expect_errors = .{ .contains = case[1] };
        error_tests.dependOn(&check.step);
    }

    const io_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/io_uring.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zigexec", .module = mod }},
    }) });
    const run_io_tests = b.addRunArtifact(io_tests);
    b.step("test-io", "Run real io_uring integration tests (requires Linux io_uring)").dependOn(&run_io_tests.step);
    const all_tests = b.step("test-all", "Run unit and io_uring integration tests");
    all_tests.dependOn(&run_tests.step);
    all_tests.dependOn(error_tests);
    all_tests.dependOn(&run_io_tests.step);

    const example = b.addExecutable(.{
        .name = "zigexec-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/pipeline.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zigexec", .module = mod }},
        }),
    });
    b.installArtifact(example);
    b.step("run", "Run the parallel pipeline example").dependOn(&b.addRunArtifact(example).step);
    const io_example = b.addExecutable(.{
        .name = "zigexec-io-uring",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/io_uring.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zigexec", .module = mod }},
        }),
    });
    b.installArtifact(io_example);
    b.step("run-io", "Run the io_uring file pipeline").dependOn(&b.addRunArtifact(io_example).step);
    const echo_example = b.addExecutable(.{
        .name = "zigexec-tcp-echo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/tcp_echo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zigexec", .module = mod }},
        }),
    });
    b.installArtifact(echo_example);
    const run_echo = b.addRunArtifact(echo_example);
    run_echo.addPassthruArgs();
    b.step("run-echo", "Run the io_uring TCP echo server ([port] [--once])").dependOn(&run_echo.step);
    const micro = b.addExecutable(.{
        .name = "zigexec-micro",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/micro.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zigexec", .module = mod }},
        }),
    });
    const install_micro = b.addInstallArtifact(micro, .{});
    const run_micro = b.addRunArtifact(micro);
    run_micro.addPassthruArgs();
    const bench = b.step("bench", "Run CPU-bound microbenchmarks (use -Doptimize=ReleaseFast)");
    bench.dependOn(&install_micro.step);
    bench.dependOn(&run_micro.step);
    const echo_test = b.addSystemCommand(&.{ "python3", "tests/tcp_echo.py" });
    echo_test.addArtifactArg(echo_example);
    const echo_unit = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/tcp_echo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zigexec", .module = mod }},
        }),
    });
    const run_echo_unit = b.addRunArtifact(echo_unit);
    const test_echo = b.step("test-echo", "Test the TCP echo example on loopback (requires Python 3)");
    test_echo.dependOn(&echo_test.step);
    test_echo.dependOn(&run_echo_unit.step);
}
