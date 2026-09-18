const linux = @import("std").os.linux;
const io = @import("../../io/request.zig");

pub fn decode(kind: io.Kind, result: i32) io.Result {
    if (result >= 0) return .{ .value = @intCast(result) };
    const err: linux.E = @fromBackingInt(@as(u16, @intCast(-result)));
    if (err == .CANCELED) return .stopped;
    if (kind == .sleep and err == .TIME) return .{ .value = 0 };
    return .{ .err = switch (err) {
        .BADF => error.BadFileDescriptor,
        .NOENT => error.FileNotFound,
        .ACCES, .PERM => error.AccessDenied,
        .INVAL => error.InvalidArgument,
        .NOMEM, .NOBUFS => error.SystemResources,
        .AGAIN => error.WouldBlock,
        .PIPE => error.BrokenPipe,
        .CONNRESET => error.ConnectionReset,
        .CONNREFUSED => error.ConnectionRefused,
        .CONNABORTED => error.ConnectionAborted,
        .TIMEDOUT => error.TimedOut,
        .NOTSOCK => error.NotSocket,
        .ISDIR => error.IsDirectory,
        .NOTDIR => error.NotDirectory,
        .EXIST => error.PathAlreadyExists,
        .NOSPC => error.NoSpaceLeft,
        .FBIG => error.FileTooBig,
        .ROFS => error.ReadOnlyFileSystem,
        .MFILE, .NFILE => error.FileDescriptorQuotaExceeded,
        .OPNOTSUPP, .NOSYS => error.OperationNotSupported,
        .INTR => error.Interrupted,
        .IO => error.InputOutput,
        else => error.UnexpectedIoError,
    } };
}
