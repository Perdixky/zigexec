//! Specialize the I/O namespace once for a concrete context pointer type.
const io = @import("root.zig");
pub fn For(comptime Context: type) type {
    return struct {
        pub const Schedule = io.Schedule(Context);
        pub const ReadSome = io.ReadSome(Context);
        pub fn readSome(context: Context, fd: i32, buffer: []u8, offset: u64) ReadSome {
            return io.readSome(context, fd, buffer, offset);
        }
        pub const WriteSome = io.WriteSome(Context);
        pub fn writeSome(context: Context, fd: i32, buffer: []const u8, offset: u64) WriteSome {
            return io.writeSome(context, fd, buffer, offset);
        }
        pub const Recv = io.Recv(Context);
        pub fn recv(context: Context, fd: i32, buffer: []u8, flags: u32) Recv {
            return io.recv(context, fd, buffer, flags);
        }
        pub const Send = io.Send(Context);
        pub fn send(context: Context, fd: i32, buffer: []const u8, flags: u32) Send {
            return io.send(context, fd, buffer, flags);
        }
        pub const SendAll = io.SendAll(Context);
        pub fn sendAll(context: Context, fd: i32, buffer: []const u8, flags: u32) SendAll {
            return io.sendAll(context, fd, buffer, flags);
        }
        pub const SleepFor = io.SleepFor(Context);
        pub fn sleepFor(context: Context, nanoseconds: u64) SleepFor {
            return io.sleepFor(context, nanoseconds);
        }
        pub const OpenAt = io.OpenAt(Context);
        pub fn openAt(context: Context, dir: i32, path: [:0]const u8, flags: u32, mode: u32) OpenAt {
            return io.openAt(context, dir, path, flags, mode);
        }
        pub const Close = io.Close(Context);
        pub fn close(context: Context, fd: i32) Close {
            return io.close(context, fd);
        }
        pub const Fsync = io.Fsync(Context);
        pub fn fsync(context: Context, fd: i32) Fsync {
            return io.fsync(context, fd);
        }
        pub const Accept = io.Accept(Context);
        pub fn accept(context: Context, fd: i32, flags: u32) Accept {
            return io.accept(context, fd, flags);
        }
        pub const Connect = io.Connect(Context);
        pub fn connect(context: Context, fd: i32, address: *const @import("std").posix.sockaddr, length: @import("std").posix.socklen_t) Connect {
            return io.connect(context, fd, address, length);
        }
    };
}
