#!/usr/bin/env python3
"""Isolated io_uring batching/taskrun ablations; production src/ is never edited."""
import argparse, hashlib, json, random, shutil, subprocess
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import run as bench
import profile as prof

ROOT, CACHE = bench.ROOT, bench.CACHE
NAMES = ['cq128', 'batch256', 'owner', 'defer', 'batch-defer']

def replace(text, old, new):
    if text.count(old) != 1:
        raise RuntimeError(f'probe no longer matches source: {old!r}')
    return text.replace(old, new, 1)

def variant(text, name):
    if name == 'cq128':
        text = replace(text, 'var cqes: [64]linux.io_uring_cqe', 'var cqes: [128]linux.io_uring_cqe')
    if name in ('batch256', 'batch-defer'):
        text = replace(text, 'entries: u16 = 64', 'entries: u16 = 256')
        text = replace(text, 'var cqes: [64]linux.io_uring_cqe', 'var cqes: [256]linux.io_uring_cqe')
    if name in ('owner', 'defer', 'batch-defer'):
        flags = '0' if name == 'owner' else 'linux.IORING_SETUP_SINGLE_ISSUER | linux.IORING_SETUP_DEFER_TASKRUN | linux.IORING_SETUP_COOP_TASKRUN'
        text = replace(text, 'closing: std.atomic.Value(bool)', '''boot_done: bool = false,
boot_error: ?anyerror = null,
boot_condition: sync.Condition = .{},
boot_options: Options,
closing: std.atomic.Value(bool)''')
        text = replace(text, '''    var ring = try linux.IoUring.init(options.entries, 0);
    errdefer ring.deinit();
    if (ring.features & linux.IORING_FEAT_NODROP == 0) return error.SystemOutdated;
''', '')
        text = replace(text, '''    self.* = .{ .allocator = allocator, .ring = ring, .wake_fd = fd };
    self.worker = try std.Thread.spawn(.{}, run, .{self});
    return self;''', '''    self.* = .{ .allocator = allocator, .ring = undefined, .wake_fd = fd, .boot_options = options };
    self.worker = try std.Thread.spawn(.{}, initializeAndRun, .{self});
    self.mutex.lock();
    while (!self.boot_done) self.boot_condition.waitForSignal(&self.mutex);
    const boot_error = self.boot_error;
    self.mutex.unlock();
    if (boot_error) |err| {
        self.worker.join();
        return err;
    }
    return self;''')
        text += '''
fn bootFinished(self: *Context, err: ?anyerror) void {
    self.mutex.lock();
    self.boot_error = err;
    self.boot_done = true;
    self.boot_condition.signal();
    self.mutex.unlock();
}
fn initializeAndRun(self: *Context) void {
    var ring = linux.IoUring.init(self.boot_options.entries, FLAGS) catch |err| {
        self.bootFinished(err);
        return;
    };
    if (ring.features & linux.IORING_FEAT_NODROP == 0) {
        ring.deinit();
        self.bootFinished(error.SystemOutdated);
        return;
    }
    self.ring = ring;
    self.bootFinished(null);
    self.run();
}
'''.replace('FLAGS', flags)
    return text

def build(name):
    destination = CACHE/'kernel-probe'/name
    shutil.copytree(ROOT/'src', destination/'src', dirs_exist_ok=True)
    shutil.copytree(ROOT/'examples', destination/'examples', dirs_exist_ok=True)
    path = destination/'src/backends/io_uring/context.zig'
    modified = variant(path.read_text(), name)
    path.write_text(modified)
    label = 'kernel-'+name
    command = ['zig','build-exe','-fllvm','--dep','zigexec','-O','ReleaseFast','-mcpu=native',f'-Mroot={destination}/examples/tcp_echo.zig','-O','ReleaseFast','-mcpu=native',f'-Mzigexec={destination}/src/root.zig',f'-femit-bin={CACHE}/{label}-echo']
    subprocess.run(command,check=True,cwd=ROOT,stdout=subprocess.DEVNULL)
    logs = {}
    # Only the backend changes; these cover real I/O, cancellation pressure,
    # address reuse, queued/local dispatch, shutdown, and echo owner cleanup.
    for test in [ROOT/'tests/io_uring.zig', destination/'examples/tcp_echo.zig']:
        cmd = ['zig','test','-fllvm','--dep','zigexec','-O','ReleaseFast',f'-Mroot={test}','-O','ReleaseFast',f'-Mzigexec={destination}/src/root.zig']
        result = subprocess.run(cmd,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=120)
        logs[str(test)] = {'command':cmd,'output':result.stdout,'returncode':result.returncode}
        if result.returncode: raise RuntimeError(f'{name} failed {test}:\n{result.stdout}')
    print('Built and tested',label,flush=True)
    return label, {'context_source':modified,'command':command,'tests':logs,'binary_sha256':hashlib.sha256((CACHE/f'{label}-echo').read_bytes()).hexdigest()}

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-only',action='store_true')
    parser.add_argument('--measure',action='store_true')
    parser.add_argument('--output',type=Path,default=CACHE/'perf-kernel-probe-stat')
    args=parser.parse_args()
    args.output=args.output.resolve()
    manifest_path=CACHE/'kernel-probe/build.json'
    if not args.measure:
        original=json.loads((CACHE/'build.json').read_text())
        for relative,digest in original['source_sha256'].items():
            if hashlib.sha256((ROOT/relative).read_bytes()).hexdigest()!=digest:raise RuntimeError(f'source changed: {relative}')
        with ThreadPoolExecutor(max_workers=2) as pool:
            variants=dict(pool.map(build,NAMES))
        manifest={'base':original,'variants':variants,'script':Path(__file__).read_text()}
        manifest_path.write_text(json.dumps(manifest,indent=2)+'\n')
    else:
        manifest=json.loads(manifest_path.read_text())
    if args.build_only:return
    libraries=['zigexec',*manifest['variants'],'libxev','zio']
    for label in libraries:
        expected=manifest['variants'][label]['binary_sha256'] if label in manifest['variants'] else manifest['base']['binary_sha256'][f'{label}-echo']
        assert hashlib.sha256((CACHE/f'{label}-echo').read_bytes()).hexdigest()==expected
    args.output.mkdir(parents=True,exist_ok=True)
    args.server_cpu=1;args.client_cpus=[2,3,4,5];args.bytes=64
    args.seconds=10;args.warmup=2;args.record_event='cycles'
    (args.output/'manifest.json').write_text(json.dumps({'build':manifest,'config':{**vars(args),'output':str(args.output)}},indent=2)+'\n')
    (args.output/'profile.py').write_text(Path(prof.__file__).read_text())
    (args.output/'kernel_probe.py').write_text(Path(__file__).read_text())
    for label in libraries:bench.verify(label,1)
    rng=random.Random(20260920)
    for repetition in range(3):
        order=list(libraries);rng.shuffle(order)
        for label in order:prof.capture(label,256,'stat',repetition,args)

if __name__=='__main__':main()
