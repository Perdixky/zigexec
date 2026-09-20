#!/usr/bin/env python3
"""Fetch pinned upstreams/toolchain into .bench-cache and build benchmark binaries."""
import argparse
import hashlib
import re
import json
import platform
import shutil
import subprocess
import tarfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / ".bench-cache"
PINS = {
    "libxev": ("https://github.com/mitchellh/libxev.git", "9ce8e8e6ff89e583258a7f8e7adeeeaeae8611bf"),
    "zio": ("https://github.com/lalinsky/zio.git", "b3475afacc7674f01842a9b1e7499f0976972f22"),
}
ZIG_VERSION = "0.17.0-dev.2127+e90365cd5"
ZIG16_URL = "https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz"
ZIG16_SHA = "70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00"


def output(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def run(args):
    print("+", " ".join(map(str, args)), flush=True)
    subprocess.run(args, cwd=ROOT, check=True)


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zig", default="zig")
    parser.add_argument("--zig016", help="Existing Zig 0.16 binary; otherwise download the pinned official Linux x86_64 build")
    parser.add_argument("--baseline-ref", help="Also build a zigexec baseline commit in isolated cache storage for interleaved comparison")
    parser.add_argument("--baseline-snapshot", type=Path, help="Use a saved zigexec-echo + build.json pair as baseline (including uncommitted optimizations)")
    parser.add_argument("--structured-snapshot", type=Path, help="Also compare a saved implementation with structured task ownership, as structured-echo")
    args = parser.parse_args()
    if args.baseline_ref and args.baseline_snapshot:
        parser.error("choose a baseline ref or snapshot, not both")
    CACHE.mkdir(exist_ok=True)
    if platform.system() != "Linux" or platform.machine() != "x86_64":
        parser.error("this benchmark currently targets Linux x86_64")
    zig = str(Path(shutil.which(args.zig) or args.zig).resolve())
    if output(zig, "version") != ZIG_VERSION:
        parser.error(f"zigexec/zio benchmark requires {ZIG_VERSION}; pass --zig")
    for name, (url, commit) in PINS.items():
        repo = CACHE / name
        if not repo.exists():
            run(["git", "init", str(repo)])
            run(["git", "-C", str(repo), "remote", "add", "origin", url])
        if output("git", "-C", str(repo), "status", "--porcelain"):
            raise RuntimeError(f"refusing to modify dirty dependency {repo}")
        if subprocess.run(["git", "-C", str(repo), "cat-file", "-e", commit], capture_output=True).returncode:
            run(["git", "-C", str(repo), "fetch", "--depth=1", "origin", commit])
        run(["git", "-C", str(repo), "checkout", "--detach", commit])
    zig16 = Path(args.zig016).resolve() if args.zig016 else CACHE / "zig-x86_64-linux-0.16.0/zig"
    if not zig16.exists() and not args.zig016:
        archive = CACHE / "zig-0.16.0.tar.xz"
        if not archive.exists():
            print(f"Downloading {ZIG16_URL}", flush=True)
            with urllib.request.urlopen(ZIG16_URL, timeout=180) as source, archive.open("wb") as dest:
                shutil.copyfileobj(source, dest)
        if sha(archive) != ZIG16_SHA:
            raise RuntimeError(f"checksum mismatch: remove {archive} and retry")
        with tarfile.open(archive) as tar:
            tar.extractall(CACHE, filter="data")
    if output(str(zig16), "version") != "0.16.0":
        parser.error("libxev requires Zig 0.16.0")
    commands = []

    def compile_server(name, compiler, source, imports, libc=False):
        command = [str(compiler), "build-exe", "-fllvm"] + (["-lc"] if libc else [])
        command += ["--dep", imports[0][0]]
        command += ["-O", "ReleaseFast", "-mcpu=native", f"-Mroot={source}"]
        for module, deps, path in imports:
            for dep in deps:
                command += ["--dep", dep]
            command += ["-O", "ReleaseFast", "-mcpu=native", f"-M{module}={path}"]
        command += [f"-femit-bin={CACHE / name}"]
        run(command)
        commands.append(command)

    compile_server("zigexec-echo", zig, "examples/tcp_echo.zig", [("zigexec", [], "src/root.zig")])
    baseline = None
    if args.baseline_ref:
        commit = output("git", "rev-parse", "--verify", args.baseline_ref + "^{commit}")
        if not re.fullmatch(r"[0-9a-f]{40}", commit):
            raise RuntimeError("invalid baseline commit")
        destination = CACHE / "baseline" / commit
        paths = output("git", "ls-tree", "-r", "--name-only", commit, "--", "src", "examples/tcp_echo.zig").splitlines()
        hashes = {}
        for relative in paths:
            path = destination / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(subprocess.check_output(["git", "show", f"{commit}:{relative}"], cwd=ROOT))
            hashes[relative] = sha(path)
        compile_server("baseline-echo", zig, destination / "examples/tcp_echo.zig", [("zigexec", [], destination / "src/root.zig")])
        baseline = {"commit": commit, "source_sha256": hashes}
    elif args.baseline_snapshot:
        saved = json.loads((args.baseline_snapshot / "build.json").read_text())
        binary = args.baseline_snapshot / "zigexec-echo"
        if sha(binary) != saved["binary_sha256"]["zigexec-echo"]:
            raise RuntimeError("baseline snapshot binary differs from its manifest")
        shutil.copy2(binary, CACHE / "baseline-echo")
        baseline = {"snapshot": str(args.baseline_snapshot), "build": saved}
    structured = None
    if args.structured_snapshot:
        saved = json.loads((args.structured_snapshot / "build.json").read_text())
        binary = args.structured_snapshot / "zigexec-echo"
        if sha(binary) != saved["binary_sha256"]["zigexec-echo"]:
            raise RuntimeError("structured snapshot binary differs from its manifest")
        shutil.copy2(binary, CACHE / "structured-echo")
        structured = {"snapshot": str(args.structured_snapshot), "build": saved}
    compile_server("libxev-echo", zig16, "benchmarks/libxev_echo.zig", [("xev", [], ".bench-cache/libxev/src/main.zig")])
    compile_server("zio-echo", zig, "benchmarks/zio_echo.zig", [
        ("zio", ["zio_options"], ".bench-cache/zio/src/zio.zig"),
        ("zio_options", [], "benchmarks/zio_options.zig"),
    ], libc=True)
    command = ["gcc", "-std=c11", "-O3", "-march=native", "-Wall", "-Wextra", "-Werror", "benchmarks/echo_load.c", "-o", str(CACHE / "echo-load")]
    run(command)
    commands.append(command)
    sources = sorted((ROOT / "src").rglob("*.zig")) + [ROOT / "examples/tcp_echo.zig"] + sorted((ROOT / "benchmarks").glob("*.zig")) + [ROOT / "benchmarks/echo_load.c"]
    manifest = {
        "baseline": baseline,
        "structured": structured,
        "zigexec_commit": output("git", "rev-parse", "HEAD"),
        "zigexec_diff": output("git", "diff", "--", "src", "examples/tcp_echo.zig"),
        "zigexec_untracked_sources": {p: (ROOT / p).read_text() for p in output("git", "ls-files", "--others", "--exclude-standard", "--", "src", "examples/tcp_echo.zig").splitlines()},
        "dependencies": {name: {"url": url, "commit": commit} for name, (url, commit) in PINS.items()},
        "compilers": {"zigexec": output(zig, "version"), "libxev": output(str(zig16), "version"), "zio": output(zig, "version"), "client": output("gcc", "--version").splitlines()[0]},
        "commands": commands,
        "source_sha256": {str(p.relative_to(ROOT)): sha(p) for p in sources},
        "binary_sha256": {name: sha(CACHE / name) for name in ["zigexec-echo", "libxev-echo", "zio-echo", "echo-load"] + (["baseline-echo"] if baseline else []) + (["structured-echo"] if structured else [])},
    }
    (CACHE / "build.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
