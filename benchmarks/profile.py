#!/usr/bin/env python3
"""Profile validated echo traffic with perf, gating events to the steady-state window.
Requires perf and noninteractive sudo for kernel counters; never changes sysctls.
"""
import argparse
import hashlib
import json
import os
import random
import select
import signal
import subprocess
import time
from pathlib import Path

import run as bench

EVENTS = ["cycles:u", "cycles:k", "instructions:u", "instructions:k", "branch-misses:u", "cache-misses:u", "task-clock", "context-switches", "cpu-migrations", "syscalls:sys_enter_io_uring_enter", "syscalls:sys_enter_futex", "syscalls:sys_enter_read", "syscalls:sys_enter_write"]


def capture(library, connections, mode, repetition, args):
    directory = args.output / f"{library}-c{connections}-{mode}-{repetition}"
    directory.mkdir(parents=True, exist_ok=False)
    control = directory / "control.fifo"
    ack = directory / "ack.fifo"
    os.mkfifo(control)
    os.mkfifo(ack)
    control_fd = os.open(control, os.O_RDWR | os.O_NONBLOCK)
    ack_fd = os.open(ack, os.O_RDWR | os.O_NONBLOCK)
    clients = []
    profiler = None
    log = (directory / "perf.log").open("w")

    def command(value):
        start = time.monotonic_ns()
        os.write(control_fd, (value + "\n").encode())
        if not select.select([ack_fd], [], [], 10)[0]:
            raise RuntimeError(f"perf {value} timed out: {(directory / 'perf.log').read_text()}")
        reply = os.read(ack_fd, 4096)
        if reply.strip(b"\x00\n ") != b"ack":
            raise RuntimeError(f"unexpected perf control acknowledgment: {reply!r}")
        return {"sent_ns": start, "ack_ns": time.monotonic_ns()}

    try:
        with bench.server(library, args.server_cpu) as (server, port):
            workers = min(connections, len(args.client_cpus))
            for i in range(workers):
                client = subprocess.Popen(["taskset", "-c", str(args.client_cpus[i]), str(bench.CACHE / "echo-load"), str(port), str(connections // workers + (i < connections % workers)), str(args.bytes)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                clients.append(client)
            for client in clients:
                if bench.ready_line(client) != "ready":
                    raise RuntimeError("load generator not ready")
            tids = sorted(int(p.name) for p in Path(f"/proc/{server.pid}/task").iterdir())
            events = EVENTS if mode == "stat" else [args.record_event]
            cmd = ["sudo", "-n", "perf", mode, "-p", str(server.pid), "-D", "-1", "--control", f"fifo:{control},{ack}", "-e", ",".join(events)]
            if mode == "stat":
                cmd += ["-x", ";", "-o", str(directory / "stat.csv")]
            else:
                cmd += ["-F", "499", "--call-graph", "dwarf,8192", "-o", str(directory / "perf.data"), "--timestamp", "--sample-cpu"]
            profiler = subprocess.Popen(cmd, stdout=log, stderr=log)
            command("disable") # Also confirms that all server threads are attached.
            start = time.monotonic_ns() + 200_000_000
            measure = start + round(args.warmup * 1e9)
            end = measure + round(args.seconds * 1e9)
            for client in clients:
                client.stdin.write(f"{start} {measure} {end}\n")
                client.stdin.flush()
            bench.wait_until(measure)
            before = bench.process_stats(server.pid)
            enable = command("enable")
            bench.wait_until(end)
            disable = command("disable")
            after = bench.process_stats(server.pid)
            # perf runs privileged; use its control channel for sampling and a
            # narrowly targeted signal for flushing the exact profiler process.
            subprocess.run(["sudo", "-n", "kill", "-INT", str(profiler.pid)], check=True)
            profiler.wait(timeout=30)
            outputs = []
            for client in clients:
                out, err = client.communicate(timeout=15)
                if client.returncode:
                    raise RuntimeError(err)
                result = json.loads(out)
                assert sum(n for _, n in result["histogram_us"]) == result["completed"]
                outputs.append(result)
            completed = sum(r["completed"] for r in outputs)
            if not completed or server.poll() is not None:
                raise RuntimeError("invalid run")
            metadata = {"library": library, "connections": connections, "bytes": args.bytes, "mode": mode, "repetition": repetition, "server_pid": server.pid, "server_tids": tids, "perf_command": cmd, "perf_exit_code": profiler.returncode, "measure_start_ns": measure, "measure_end_ns": end, "enable": enable, "disable": disable, "completed": completed, "rps": completed / args.seconds, "cpu_us_per_echo": (after["cpu_seconds"] - before["cpu_seconds"]) * 1e6 / completed, "client_results": outputs}
            (directory / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
            print(f"{library} c={connections} {mode} #{repetition}: {completed / args.seconds:,.0f} echo/s; enable delay {(enable['ack_ns'] - measure)/1e6:.2f} ms", flush=True)
            return metadata
    finally:
        if profiler is not None and profiler.poll() is None:
            subprocess.run(["sudo", "-n", "kill", "-INT", str(profiler.pid)], check=False)
            profiler.wait(timeout=30)
        for client in clients:
            bench.stop(client)
        log.close()
        os.close(control_fd)
        os.close(ack_fd)
        control.unlink()
        ack.unlink()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--libraries", default="zigexec,libxev,zio")
    parser.add_argument("--connections", default="32,256")
    parser.add_argument("--bytes", type=int, default=64)
    parser.add_argument("--seconds", type=float, default=10)
    parser.add_argument("--warmup", type=float, default=2)
    parser.add_argument("--repetitions", type=int, default=3)
    parser.add_argument("--mode", choices=["stat", "record"], default="stat")
    parser.add_argument("--record-event", default="cycles", help="cycles for whole-process profile; cycles:u for detailed userspace sampling")
    parser.add_argument("--server-cpu", type=int, default=1)
    parser.add_argument("--client-cpus", default="2,3,4,5")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output = args.output.resolve()
    args.client_cpus = list(map(int, args.client_cpus.split(",")))
    libraries = args.libraries.split(",")
    connections = list(map(int, args.connections.split(",")))
    if args.seconds <= 0 or args.warmup <= 0 or args.repetitions < 1 or any(c < 1 for c in connections) or not 8 <= args.bytes <= 1048576:
        parser.error("invalid workload")
    cpus = [args.server_cpu, *args.client_cpus]
    if not args.client_cpus or len(cpus) != len(set(cpus)) or not set(cpus) <= os.sched_getaffinity(0):
        parser.error("CPUs must be distinct and allowed")
    siblings = [Path(f"/sys/devices/system/cpu/cpu{c}/topology/thread_siblings_list").read_text().strip() for c in cpus]
    if len(siblings) != len(set(siblings)):
        parser.error("select distinct physical cores")
    manifest = json.loads((bench.CACHE / "build.json").read_text())
    for lib in libraries:
        name = f"{lib}-echo"
        if hashlib.sha256((bench.CACHE / name).read_bytes()).hexdigest() != manifest["binary_sha256"][name]:
            raise RuntimeError(f"binary differs from manifest: {name}")
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "profile.py").write_bytes(Path(__file__).read_bytes())
    info = {"config": {**vars(args), "output": str(args.output)}, "build": manifest, "perf_version": subprocess.check_output(["perf", "--version"], text=True).strip(), "kernel": os.uname().release, "perf_event_paranoid": Path('/proc/sys/kernel/perf_event_paranoid').read_text().strip(), "script_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}
    (args.output / "manifest.json").write_text(json.dumps(info, indent=2) + "\n")
    for lib in libraries:
        bench.verify(lib, args.server_cpu)
    rng = random.Random(20260920)
    for repetition in range(args.repetitions):
        for count in connections:
            order = list(libraries)
            rng.shuffle(order)
            for lib in order:
                capture(lib, count, args.mode, repetition, args)


if __name__ == "__main__":
    main()
