#!/usr/bin/env python3
"""Linux loopback TCP benchmark; run build.py first. No third-party Python modules."""
import argparse
import concurrent.futures
import contextlib
import datetime
import hashlib
import json
import math
import os
import platform
import random
import re
import select
import socket
import statistics
import struct
import subprocess
import threading
import time
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / ".bench-cache"
LIBRARIES = ["zigexec", "libxev", "zio"]
SCENARIOS = [(64, 1), (64, 32), (64, 256), (4096, 1), (4096, 32), (16384, 32)]


def ready_line(process, timeout=20):
    ready, _, _ = select.select([process.stdout], [], [], timeout)
    if not ready:
        raise RuntimeError(f"process {process.pid} startup timed out")
    line = process.stdout.readline()
    if not line:
        raise RuntimeError(f"process {process.pid} exited during startup")
    return line.strip()


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
    for stream in (process.stdin, process.stdout, process.stderr):
        if stream:
            stream.close()


@contextlib.contextmanager
def server(library, cpu):
    process = subprocess.Popen(
        ["taskset", "-c", str(cpu), str(CACHE / f"{library}-echo"), "0"],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )
    try:
        line = ready_line(process)
        match = re.fullmatch(r"listening on 127\.0\.0\.1:(\d+)", line)
        if not match:
            raise RuntimeError(f"{library}: unexpected startup output {line!r}")
        yield process, int(match[1])
    finally:
        stop(process)


def receive_exact(sock, count):
    data = bytearray()
    while len(data) < count:
        part = sock.recv(count - len(data))
        if not part:
            raise RuntimeError("unexpected EOF")
        data.extend(part)
    return data


def verify(library, cpu):
    """Same correctness gates for all servers; never time invalid echoes."""
    with server(library, cpu) as (process, port):
        def connect():
            return socket.create_connection(("127.0.0.1", port), timeout=10)

        payload = bytes(range(256)) * 4096 + b"tail\x00\xff"
        with connect() as client:
            def send_fragments():
                for i in range(0, len(payload), 7919):
                    client.sendall(payload[i:i + 7919])
                client.shutdown(socket.SHUT_WR)

            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
                sent = executor.submit(send_fragments)
                if receive_exact(client, len(payload)) != payload or client.recv(1) != b"":
                    raise RuntimeError("fragmented/half-close echo mismatch")
                sent.result(timeout=10)
        barrier = threading.Barrier(32, timeout=10)
        with connect() as idle:
            def exchange(index):
                data = bytes([index]) * (20000 + index * 997)
                with connect() as client:
                    client.sendall(data)
                    if receive_exact(client, len(data)) != data:
                        raise RuntimeError("concurrent echo mismatch")
                    barrier.wait()
                    client.shutdown(socket.SHUT_WR)
                    if client.recv(1) != b"":
                        raise RuntimeError("expected EOF")

            with concurrent.futures.ThreadPoolExecutor(max_workers=32) as executor:
                list(executor.map(exchange, range(32)))
            with connect() as reset:
                reset.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
                reset.sendall(b"reset" * 4096)
            idle.sendall(b"alive")
            if receive_exact(idle, 5) != b"alive":
                raise RuntimeError("idle connection failed")
        with connect() as client:
            client.sendall(b"reconnected")
            if receive_exact(client, 11) != b"reconnected":
                raise RuntimeError("reconnect failed")
        if process.poll() is not None:
            raise RuntimeError("server exited during verification")
    print(f"verified {library}: binary data, 1 MiB fragmentation, half-close, 32 clients + idle, reset/reconnect", flush=True)


def process_stats(pid):
    # /proc/PID/stat reports process-wide CPU, including the reactor thread.
    fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
    status = Path(f"/proc/{pid}/status").read_text()
    return {
        "time_ns": time.monotonic_ns(),
        "cpu_seconds": (int(fields[11]) + int(fields[12])) / os.sysconf("SC_CLK_TCK"),
        "rss_kib": int(re.search(r"VmRSS:\s+(\d+)", status)[1]),
        "peak_rss_kib": int(re.search(r"VmHWM:\s+(\d+)", status)[1]),
        "threads": int(re.search(r"Threads:\s+(\d+)", status)[1]),
    }


def wait_until(timestamp):
    remaining = (timestamp - time.monotonic_ns()) / 1e9
    if remaining > 0:
        time.sleep(remaining)


def percentile(histogram, quantile):
    target = math.ceil(sum(histogram.values()) * quantile)
    total = 0
    for bucket, count in sorted(histogram.items()):
        total += count
        if total >= target:
            return bucket
    raise RuntimeError("empty latency histogram")


def trial(library, size, connections, args):
    clients = []
    with server(library, args.server_cpu) as (process, port):
        try:
            workers = min(connections, len(args.client_cpus))
            for i in range(workers):
                count = connections // workers + (i < connections % workers)
                client = subprocess.Popen(
                    ["taskset", "-c", str(args.client_cpus[i]), str(CACHE / "echo-load"), str(port), str(count), str(size)],
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                )
                clients.append(client)
            for client in clients:
                if ready_line(client) != "ready":
                    raise RuntimeError("unexpected client startup output")
            start = time.monotonic_ns() + 200_000_000
            measure_start = start + round(args.warmup * 1e9)
            end = measure_start + round(args.seconds * 1e9)
            for client in clients:
                client.stdin.write(f"{start} {measure_start} {end}\n")
                client.stdin.flush()
            wait_until(measure_start)
            before = process_stats(process.pid)
            wait_until(end)
            after = process_stats(process.pid)
            outputs = []
            for client in clients:
                out, err = client.communicate(timeout=15)
                if client.returncode:
                    raise RuntimeError(f"load generator failed: {err}")
                outputs.append(json.loads(out))
            if process.poll() is not None:
                raise RuntimeError("server exited during benchmark")
            histogram = Counter()
            for result in outputs:
                histogram.update(dict(result["histogram_us"]))
            completed = sum(r["completed"] for r in outputs)
            if completed == 0 or sum(histogram.values()) != completed:
                raise RuntimeError("invalid completion count")
            server_cpu = after["cpu_seconds"] - before["cpu_seconds"]
            sample_seconds = (after["time_ns"] - before["time_ns"]) / 1e9
            return {
                "library": library, "bytes": size, "connections": connections,
                "workers": workers, "completed": completed,
                "rps": completed / args.seconds,
                "payload_mib_s": completed * size / args.seconds / 1024**2,
                "mean_us": sum(r["latency_sum_ns"] for r in outputs) / completed / 1000,
                "p50_us": percentile(histogram, .50), "p95_us": percentile(histogram, .95), "p99_us": percentile(histogram, .99),
                "max_us": max(r["max_latency_ns"] for r in outputs) / 1000,
                "server_cpu_seconds": server_cpu,
                "server_cpu_percent": 100 * server_cpu / sample_seconds,
                "server_cpu_us_per_echo": server_cpu * 1e6 / completed,
                "server_sample_seconds": sample_seconds,
                "server_rss_kib": after["rss_kib"], "server_peak_rss_kib": after["peak_rss_kib"],
                "server_threads": after["threads"],
                "client_cpu_percent": 100 * sum(r["cpu_seconds"] for r in outputs) / args.seconds,
                "client_cpu_percent_per_worker": [100 * r["cpu_seconds"] / args.seconds for r in outputs],
                "client_results": outputs,
            }
        finally:
            for client in clients:
                stop(client)


def report(data):
    groups = defaultdict(list)
    for row in data["trials"]:
        groups[(row["bytes"], row["connections"], row["library"])].append(row)
    lines = ["# TCP echo benchmark", "", "Medians across independent trials. RPS counts complete validated echoes; MiB/s counts payload in one direction. p50/p99 are medians of each trial's RTT percentiles (1 µs histogram buckets).", "", "| Bytes | Connections | Library | Echoes/s | Min–max | MiB/s | p50 µs | p99 µs | Server CPU % | CPU µs/echo | RSS MiB |", "|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|"]
    for (size, connections, library), rows in sorted(groups.items()):
        def median(key):
            return statistics.median(r[key] for r in rows)
        lines.append(f"| {size} | {connections} | {library} | {median('rps'):,.0f} | {min(r['rps'] for r in rows):,.0f}–{max(r['rps'] for r in rows):,.0f} | {median('payload_mib_s'):.1f} | {median('p50_us'):.0f} | {median('p99_us'):.0f} | {median('server_cpu_percent'):.1f} | {median('server_cpu_us_per_echo'):.2f} | {median('server_rss_kib') / 1024:.1f} |")
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server-cpu", type=int, default=1)
    parser.add_argument("--client-cpus", default="2,3,4,5")
    parser.add_argument("--seconds", type=float, default=3)
    parser.add_argument("--warmup", type=float, default=1)
    parser.add_argument("--repetitions", type=int, default=5)
    parser.add_argument("--seed", type=int, default=20260919)
    parser.add_argument("--libraries", default=",".join(LIBRARIES))
    parser.add_argument("--scenarios", help="Comma-separated bytes:connections; default includes six cases")
    parser.add_argument("--verify-only", action="store_true")
    parser.add_argument("--output", type=Path, default=ROOT / "benchmarks/results/latest.json")
    args = parser.parse_args()
    args.client_cpus = [int(cpu) for cpu in args.client_cpus.split(",")]
    libraries = args.libraries.split(",")
    scenarios = [tuple(map(int, item.split(":"))) for item in args.scenarios.split(",")] if args.scenarios else SCENARIOS
    if args.seconds <= 0 or args.warmup <= 0 or args.repetitions < 1:
        parser.error("duration, warmup and repetitions must be positive")
    if not args.client_cpus or len(set(args.client_cpus)) != len(args.client_cpus) or args.server_cpu in args.client_cpus:
        parser.error("server and client CPUs must be distinct")
    if not set([args.server_cpu, *args.client_cpus]) <= os.sched_getaffinity(0):
        parser.error("requested CPU is outside process affinity")
    if not libraries or not set(libraries) <= set([*LIBRARIES, "baseline", "structured"]):
        parser.error("unknown library")
    if any(len(s) != 2 or not 8 <= s[0] <= 1048576 or not 1 <= s[1] <= 65536 for s in scenarios):
        parser.error("invalid bytes:connections")
    # Keep load on physical cores separate from the server, including SMT siblings.
    siblings = {cpu: Path(f"/sys/devices/system/cpu/cpu{cpu}/topology/thread_siblings_list").read_text().strip() for cpu in [args.server_cpu, *args.client_cpus]}
    if len(set(siblings.values())) != len(siblings):
        parser.error("select different physical cores; SMT siblings would compete")
    manifest = json.loads((CACHE / "build.json").read_text())
    for binary, digest in manifest["binary_sha256"].items():
        if hashlib.sha256((CACHE / binary).read_bytes()).hexdigest() != digest:
            raise RuntimeError(f"binary changed since build: {binary}")
    for library in libraries:
        if f"{library}-echo" not in manifest["binary_sha256"]:
            parser.error(f"{library} was not built; use build.py --baseline-ref for a baseline")
        verify(library, args.server_cpu)
    if args.verify_only:
        return
    data = {
        "date_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "environment": {
            "kernel": platform.platform(), "lscpu": subprocess.check_output(["lscpu"], text=True),
            "governor": Path(f"/sys/devices/system/cpu/cpu{args.server_cpu}/cpufreq/scaling_governor").read_text().strip() if Path(f"/sys/devices/system/cpu/cpu{args.server_cpu}/cpufreq/scaling_governor").exists() else "unknown",
            "cpu_siblings": siblings, "loadavg_at_start": list(os.getloadavg()),
        },
        "config": {**vars(args), "output": str(args.output), "scenarios": scenarios},
        "build": manifest, "trials": [],
        "harness_sha256": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in [Path(__file__), ROOT / "benchmarks/build.py"]},
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    rng = random.Random(args.seed)
    # Interleave competitors within each scenario/round, never run servers in parallel.
    jobs = []
    for repetition in range(args.repetitions):
        shuffled = list(scenarios)
        rng.shuffle(shuffled)
        for size, connections in shuffled:
            order = list(libraries)
            rng.shuffle(order)
            jobs.extend((repetition, library, size, connections) for library in order)
    for index, (repetition, library, size, connections) in enumerate(jobs, 1):
        row = trial(library, size, connections, args)
        row["repetition"] = repetition
        data["trials"].append(row)
        temp = args.output.with_suffix(".tmp")
        temp.write_text(json.dumps(data, indent=2) + "\n")
        temp.replace(args.output)
        print(f"[{index}/{len(jobs)}] {library:7s} {size:5d} B c={connections:3d}: {row['rps']:10,.0f} echo/s p99={row['p99_us']} us cpu={row['server_cpu_percent']:.1f}% client={row['client_cpu_percent']:.1f}%", flush=True)
    args.output.with_suffix(".md").write_text(report(data))
    print(f"Saved {args.output} and {args.output.with_suffix('.md')}")


if __name__ == "__main__":
    main()
