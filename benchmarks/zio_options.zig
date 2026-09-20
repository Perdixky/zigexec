// Match upstream defaults except force io_uring (no silent epoll fallback).
pub const backend: ?[]const u8 = "io_uring";
pub const resolve_beneath_mode = enum { strict, best_effort }.strict;
pub const no_hacks = false;
pub const task_migration = true;
pub const scheduler_metrics = true;
