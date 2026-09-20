# 64 B / 256 connections: perf stat per validated echo

Three 10-second trials per binary; 2-second warmup. Values are medians of normalized counters. Kernel counters include interrupt work charged during the task, not just process system CPU.

| Library | cycles:u | instructions:u | cycles:k | instructions:k | syscalls:sys_enter_io_uring_enter | branch-misses:u | cache-misses:u |
|---|---:|---:|---:|---:|---:|---:|---:|
| baseline | 578.34 | 870.27 | 14161.92 | 13741.85 | 0.0313 | 0.71 | 22.12 |
| zigexec | 434.87 | 575.96 | 14421.58 | 13935.92 | 0.0313 | 0.31 | 20.97 |
| libxev | 149.46 | 279.24 | 13634.01 | 13751.82 | 0.0469 | 0.45 | 3.22 |
| zio | 658.05 | 1187.50 | 14060.44 | 12579.92 | 0.0275 | 2.37 | 26.46 |
