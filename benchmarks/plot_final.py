#!/usr/bin/env python3
"""Render the final report's figures from archived measurements (matplotlib)."""
import argparse
import gzip
import json
import statistics
from collections import defaultdict
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt


def read_json(path):
    raw = path.read_bytes()
    return json.loads(gzip.decompress(raw) if path.suffix == ".gz" else raw)


def save(fig, path):
    for extension in ("svg", "png"):
        fig.savefig(path.with_suffix("." + extension), dpi=180, bbox_inches="tight")
    plt.close(fig)


def main():
    results = Path(__file__).resolve().parent / "results"
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--throughput", type=Path, default=results / "2026-09-20-final.json.gz")
    parser.add_argument("--perf", type=Path, default=results / "2026-09-20-completion-perf.json.gz")
    parser.add_argument("--output-dir", type=Path, default=results)
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 10,
                         "axes.spines.top": False, "axes.spines.right": False,
                         "svg.fonttype": "none"})
    colors = {"baseline": "#8b96a5", "zigexec": "#007f78", "libxev": "#3e67b1", "zio": "#bb692e"}
    data = read_json(args.throughput)
    groups = defaultdict(list)
    for row in data["trials"]:
        groups[(row["bytes"], row["connections"], row["library"])].append(row["rps"] / 1000)
    scenarios = data["config"]["scenarios"]
    fig, axes = plt.subplots(2, 3, figsize=(11.5, 6.6))
    for ax, (size, connections) in zip(axes.flat, scenarios):
        libs = ["zigexec", "libxev", "zio"]
        samples = [groups[(size, connections, lib)] for lib in libs]
        assert all(len(x) == data["config"]["repetitions"] == 5 for x in samples)
        medians = [statistics.median(x) for x in samples]
        ax.bar(range(3), medians, color=[colors[lib] for lib in libs], width=.60, alpha=.85)
        for x, (sample, median) in enumerate(zip(samples, medians)):
            ax.scatter([x + (i - 2) * .065 for i in range(5)], sample,
                       color="#152a3a", s=14, zorder=3)
            ax.text(x, max(sample) + max(medians) * .055, f"{median:.1f}", ha="center", weight="bold")
        ax.set(xticks=range(3), xticklabels=libs, ylim=(0, max(map(max, samples)) * 1.20),
               title=f"{size:,} B / {connections} connection{'s' if connections != 1 else ''}",
               ylabel="k validated echoes/s")
        ax.grid(axis="y", alpha=.16)
        ax.set_axisbelow(True)
    fig.suptitle("Final TCP echo throughput · Linux loopback · one server core", fontsize=16, weight="bold", y=1.02)
    fig.text(.5, -.025, "Bars and labels: median. Dots: all five trials. 1 s warmup + 3 s measurement per trial.\n"
             "Ryzen 5 7500F · ReleaseFast / native · 2026-09-20 · independently restarted, interleaved servers", ha="center", color="#465263")
    fig.tight_layout()
    save(fig, args.output_dir / "2026-09-20-final-throughput")

    perf = read_json(args.perf)
    samples = defaultdict(list)
    for run in perf["directories"]["perf-completion-protocol"]["runs"]:
        for metric in ("cycles:u", "instructions:u"):
            samples[(run["metadata"]["library"], metric)].append(run["counts"][metric]["per_echo"])
    libs = ["baseline", "zigexec", "libxev", "zio"]
    fig, axes = plt.subplots(1, 2, figsize=(11.5, 4.0))
    for ax, metric in zip(axes, ("cycles:u", "instructions:u")):
        medians = [statistics.median(samples[(lib, metric)]) for lib in libs]
        ax.bar(range(4), medians, color=[colors[lib] for lib in libs], width=.6, alpha=.85)
        for x, (lib, median) in enumerate(zip(libs, medians)):
            values = samples[(lib, metric)]
            assert len(values) == 3
            ax.scatter([x + (i - 1) * .08 for i in range(3)], values, color="#152a3a", s=16, zorder=3)
            ax.text(x, max(values) + max(medians) * .05, f"{median:.0f}", ha="center", weight="bold")
        ceiling = max(max(samples[(lib, metric)]) for lib in libs)
        ax.set(xticks=range(4), xticklabels=["Previous\nprotocol", "Final\nzigexec", "libxev", "zio"],
               ylim=(0, ceiling * 1.2), ylabel=f"{metric} / validated echo",
               title=f"Final vs previous protocol: {(medians[1] / medians[0] - 1) * 100:.1f}%")
        ax.grid(axis="y", alpha=.16)
        ax.set_axisbelow(True)
    fig.suptitle("User-space CPU cost · 64 B / 256 connections", fontsize=16, weight="bold", y=1.04)
    fig.text(.5, -.08, "Independent perf batch: three trials, 2 s warmup + 10 s measurement. Dots: all trials; bars: median.\n"
             "Scaled hardware counters; server task only. Previous protocol already uses manually owned operations.", ha="center", color="#465263")
    fig.tight_layout()
    save(fig, args.output_dir / "2026-09-20-final-user-cost")


if __name__ == "__main__":
    main()
