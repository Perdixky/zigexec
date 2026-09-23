#!/usr/bin/env python3
"""Archive a profile.py output directory and summarize normalized counters."""
import argparse
import csv
import gzip
import json
import statistics
from pathlib import Path


def parse_counts(path, completed):
    counts = {}
    with path.open(newline="") as source:
        for row in csv.reader(source, delimiter=";"):
            if not row or row[0].startswith("#") or len(row) < 5:
                continue
            count = float(row[0])
            counts[row[2]] = {
                "count": count,
                "unit": row[1],
                "runtime_ns": float(row[3]),
                "running_percent": float(row[4]),
                "per_echo": count / completed,
            }
    return counts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("profile_dir", type=Path)
    parser.add_argument("--json", type=Path, required=True)
    parser.add_argument("--markdown", type=Path, required=True)
    args = parser.parse_args()

    runs = []
    for metadata_path in sorted(args.profile_dir.glob("*-stat-*/metadata.json")):
        directory = metadata_path.parent
        metadata = json.loads(metadata_path.read_text())
        runs.append({
            "metadata": metadata,
            "counts": parse_counts(directory / "stat.csv", metadata["completed"]),
            "stat_csv": (directory / "stat.csv").read_text(),
            "log": (directory / "perf.log").read_text(),
        })
    if not runs:
        raise RuntimeError(f"no stat runs found in {args.profile_dir}")

    archive = {
        "profile": {
            "manifest": json.loads((args.profile_dir / "manifest.json").read_text()),
            "script": (args.profile_dir / "profile.py").read_text(),
            "runs": runs,
        },
        "summary_script": Path(__file__).read_text(),
    }
    encoded = (json.dumps(archive, indent=2) + "\n").encode()
    args.json.write_bytes(gzip.compress(encoded, mtime=0))

    metrics = ["cycles:u", "instructions:u", "cycles:k", "instructions:k",
               "syscalls:sys_enter_io_uring_enter", "branch-misses:u", "cache-misses:u"]
    config = archive["profile"]["manifest"]["config"]
    libraries = config["libraries"].split(",")
    scenarios = sorted({(run["metadata"]["bytes"], run["metadata"]["connections"]) for run in runs})
    lines = []
    for size, connections in scenarios:
        scenario_runs = [run for run in runs if (run["metadata"]["bytes"], run["metadata"]["connections"]) == (size, connections)]
        trials = len(scenario_runs) // len(libraries)
        lines += [
            f"# {size} B / {connections} connections: perf stat per validated echo",
            "",
            f"{trials} trials per binary; {config['warmup']:g}-second warmup and {config['seconds']:g}-second measurement. Values are medians of normalized counters. Kernel counters include interrupt work charged during the task, not just process system CPU.",
            "",
            "| Library | " + " | ".join(metrics) + " |",
            "|---|" + "---:|" * len(metrics),
        ]
        for library in libraries:
            values = []
            selected = [run for run in scenario_runs if run["metadata"]["library"] == library]
            for metric in metrics:
                median = statistics.median(run["counts"][metric]["per_echo"] for run in selected)
                values.append(f"{median:.4f}" if metric.startswith("syscalls:") else f"{median:.2f}")
            lines.append(f"| {library} | " + " | ".join(values) + " |")
        lines.append("")
    args.markdown.write_text("\n".join(lines).rstrip() + "\n")


if __name__ == "__main__":
    main()
