#!/usr/bin/env python3
"""Controlled backend experiments in disposable copies; never edit src/."""
import argparse
import datetime
import hashlib
import json
import os
import platform
import random
import shutil
import subprocess
from pathlib import Path

import run as bench

ROOT = bench.ROOT
CACHE = bench.CACHE


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise RuntimeError(f"experiment no longer matches source: {old!r}")
    return text.replace(old, new, 1)


def variant_source(original, name):
    text = original
    if name in ("local-wake", "combined"):
        text = replace_once(text, "const Context = @This();", "const Context = @This();\nthreadlocal var reactor_context: ?*Context = null;")
        text = replace_once(text, "    self.mutex.unlock();\n    self.wake();\n}\n\nfn submitTask", "    self.mutex.unlock();\n    if (reactor_context != self) self.wake();\n}\n\nfn submitTask")
        text = replace_once(text, "fn run(self: *Context) void {", "fn run(self: *Context) void {\n    reactor_context = self;\n    defer reactor_context = null;")
    if name in ("cancel-scan", "combined"):
        text = replace_once(text, "active_count: usize = 0,", "active_count: usize = 0,\ncancel_scan_requested: std.atomic.Value(bool) = .init(false),")
        text = replace_once(text, "    request.cancel_requested.store(true, .release);", "    request.cancel_requested.store(true, .release);\n    self.cancel_scan_requested.store(true, .release);")
        text = replace_once(text, "        var active = self.active;", "        var active = if (closing or self.cancel_scan_requested.swap(false, .acq_rel)) self.active else null;")
        text = replace_once(text, "                pending_cancels = true;", "                pending_cancels = true;\n                self.cancel_scan_requested.store(true, .release);")
    if name == "ring256":
        text = replace_once(text, "pub const Options = struct { entries: u16 = 64 };", "pub const Options = struct { entries: u16 = 256 };")
    return text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zig", default="zig")
    parser.add_argument("--server-cpu", type=int, default=1)
    parser.add_argument("--client-cpus", default="2,3,4,5")
    parser.add_argument("--seconds", type=float, default=3)
    parser.add_argument("--warmup", type=float, default=1)
    parser.add_argument("--repetitions", type=int, default=5)
    parser.add_argument("--output", type=Path, default=ROOT / "benchmarks/results/2026-09-19-diagnosis.json")
    args = parser.parse_args()
    if "threadlocal var reactor_context" in (ROOT / "src/backends/io_uring/context.zig").read_text():
        parser.error("historical ablation script requires baseline 7da66f5; local-wake is already implemented. Use build.py --baseline-ref 7da66f5 and run.py --libraries baseline,zigexec,libxev,zio for the current comparison.")
    args.client_cpus = list(map(int, args.client_cpus.split(",")))
    if args.seconds <= 0 or args.warmup <= 0 or args.repetitions < 1:
        parser.error("duration, warmup and repetitions must be positive")
    cpus = [args.server_cpu, *args.client_cpus]
    if not args.client_cpus or len(cpus) != len(set(cpus)) or not set(cpus) <= os.sched_getaffinity(0):
        parser.error("CPUs must be distinct and within process affinity")
    siblings = [Path(f"/sys/devices/system/cpu/cpu{cpu}/topology/thread_siblings_list").read_text().strip() for cpu in cpus]
    if len(siblings) != len(set(siblings)):
        parser.error("CPUs must be on distinct physical cores")
    manifest = json.loads((CACHE / "build.json").read_text())
    version = subprocess.check_output([args.zig, "version"], text=True).strip()
    if version != manifest["compilers"]["zigexec"]:
        raise RuntimeError("diagnostic compiler differs from baseline")
    for relative, expected in manifest["source_sha256"].items():
        if hashlib.sha256((ROOT / relative).read_bytes()).hexdigest() != expected:
            raise RuntimeError(f"baseline source has changed; rerun build.py: {relative}")
    for name, expected in manifest["binary_sha256"].items():
        if hashlib.sha256((CACHE / name).read_bytes()).hexdigest() != expected:
            raise RuntimeError(f"baseline binary has changed; rerun build.py: {name}")
    names = ["local-wake", "cancel-scan", "combined", "ring256"]
    context_path = Path("backends/io_uring/context.zig")
    original = (ROOT / "src" / context_path).read_text()
    data = {
        "date_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "environment": {"kernel": platform.platform(), "lscpu": subprocess.check_output(["lscpu"], text=True), "loadavg_at_start": list(os.getloadavg()), "cpu_siblings": siblings},
        "build": manifest, "compiler": version,
        "config": {**vars(args), "output": str(args.output)}, "variants": {}, "trials": [],
        "harness_sha256": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in [Path(__file__), ROOT / "benchmarks/run.py"]},
    }
    for name in names:
        destination = CACHE / "diagnostics" / name / "src"
        shutil.copytree(ROOT / "src", destination, dirs_exist_ok=True)
        modified = variant_source(original, name)
        (destination / context_path).write_text(modified)
        command = [args.zig, "build-exe", "-fllvm", "--dep", "zigexec", "-O", "ReleaseFast", "-mcpu=native", "-Mroot=examples/tcp_echo.zig", "-O", "ReleaseFast", "-mcpu=native", f"-Mzigexec={destination / 'root.zig'}", f"-femit-bin={CACHE / (name + '-echo')}"]
        print(f"Building and testing diagnostic variant: {name}", flush=True)
        subprocess.run(command, cwd=ROOT, check=True)
        # Existing lifetime/cancellation and real-kernel tests gate experiments.
        for test in ("tests/root.zig", "tests/io_uring.zig"):
            check = subprocess.run([args.zig, "test", "-fllvm", "--dep", "zigexec", "-O", "ReleaseFast", f"-Mroot={test}", "-O", "ReleaseFast", f"-Mzigexec={destination / 'root.zig'}"], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
            if check.returncode:
                raise RuntimeError(f"{name}: {test} failed:\n{check.stderr}")
        bench.verify(name, args.server_cpu)
        data["variants"][name] = {
            "command": command,
            "context_source": modified,
            "binary_sha256": hashlib.sha256((CACHE / (name + "-echo")).read_bytes()).hexdigest(),
            "validation": "core and io_uring suites plus shared TCP correctness gates passed",
        }
    scenarios = [(64, 1), (64, 32), (64, 256)]
    rng = random.Random(20260920)
    jobs = []
    for repetition in range(args.repetitions):
        for size, connections in scenarios:
            order = ["zigexec", *names, "libxev", "zio"]
            rng.shuffle(order)
            jobs.extend((repetition, name, size, connections) for name in order)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    for index, (repetition, name, size, connections) in enumerate(jobs, 1):
        row = bench.trial(name, size, connections, args)
        row["repetition"] = repetition
        data["trials"].append(row)
        temporary = args.output.with_suffix(".tmp")
        temporary.write_text(json.dumps(data, indent=2) + "\n")
        temporary.replace(args.output)
        print(f"[{index}/{len(jobs)}] {name:12s} c={connections:3d}: {row['rps']:,.0f} echo/s cpu/echo={row['server_cpu_us_per_echo']:.2f} us", flush=True)
    args.output.with_suffix(".md").write_text(bench.report(data))


if __name__ == "__main__":
    main()
