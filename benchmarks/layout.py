#!/usr/bin/env python3
"""Measure the actual echo example's types without changing the example."""
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / ".bench-cache"
PROBE = r'''
const LayoutReceiver = struct {
    pub fn getEnv(_: *@This()) ex.Env { return .{}; }
    pub fn setValue(_: *@This(), _: *const ex.Values(.{})) void {}
    pub fn setError(_: *@This(), _: anyerror) void {}
    pub fn setStopped(_: *@This()) void {}
};
fn printLayout(comptime label: []const u8, comptime S: type) void {
    std.debug.print("{s}: sender={d}, operation={d}\n", .{ label, @sizeOf(S), @sizeOf(S.Operation(*LayoutReceiver)) });
}
pub fn main() void {
    const A = Io.Schedule.LetValue(Echo);
    const B = A.Then(Close);
    const C = B.UponError(CloseError);
    const D = C.LetStopped(CloseStopped);
    const Token = @TypeOf(@as(*ex.CountingScope, undefined).getToken());
    const Wrapped = @TypeOf(@as(Token, undefined).wrap(@as(D, undefined)));
    const Association = @TypeOf(@as(Token, undefined).tryAssociate());
    // Same fields/layout as the private Node in consumers/spawn.zig.
    const SpawnNodeLayout = struct {
        allocator: std.mem.Allocator,
        env: ex.Env,
        association: Association,
        operation: ex.Connection(Wrapped, *LayoutReceiver),
    };
    std.debug.print("Echo factory={d}; Echo loop operation={d}\n", .{ @sizeOf(Echo), @sizeOf(Echo.Loop.Operation(*LayoutReceiver)) });
    printLayout("schedule.letValue(Echo)", A);
    printLayout("+ then(Close)", B);
    printLayout("+ uponError(CloseError)", C);
    printLayout("+ letStopped(CloseStopped)", D);
    printLayout("+ scope token wrapper", Wrapped);
    std.debug.print("Connection={d}; spawn Node layout={d}\n", .{ @sizeOf(ex.Connection(Wrapped, *LayoutReceiver)), @sizeOf(SpawnNodeLayout) });
}
'''


def main():
    source = (ROOT / "examples/tcp_echo.zig").read_text()
    signature = "pub fn main(init: std.process.Init.Minimal) !void {"
    if source.count(signature) != 1:
        raise RuntimeError("echo example entry point changed")
    probe = CACHE / "echo_layout.zig"
    body = PROBE
    if "const Client = struct {" in source:
        body = r'''
pub fn main() void {
    std.debug.print("Echo storage={d}; Echo loop operation={d}\n", .{ @sizeOf(Echo), @sizeOf(Echo.Loop.Operation(*Client)) });
    std.debug.print("Client connection={d}; manually owned Client={d}\n", .{ @sizeOf(ex.Connection(Echo.Loop, *Client)), @sizeOf(Client) });
    std.debug.print("Server={d}; accept connection={d}\n", .{ @sizeOf(Server), @sizeOf(ex.Connection(Server.AcceptLoop, *Server)) });
}
'''
    probe.write_text(source.replace(signature, "pub fn echoMain(init: std.process.Init.Minimal) !void {", 1) + body)
    subprocess.run(["zig", "run", "-fllvm", "--dep", "zigexec", "-O", "ReleaseFast", f"-Mroot={probe}", "-O", "ReleaseFast", "-Mzigexec=src/root.zig"], cwd=ROOT, check=True)


if __name__ == "__main__":
    main()
