# 64 B / 256 connections: perf stat per validated echo

Three 10-second trials per binary; 2-second warmup. Values are medians of normalized counters. Kernel counters include interrupt work charged during the task, not just process system CPU.

| Library | cycles:u | instructions:u | cycles:k | instructions:k | syscalls:sys_enter_io_uring_enter | branch-misses:u | cache-misses:u |
|---|---:|---:|---:|---:|---:|---:|---:|
| baseline | 415.45 | 576.12 | 14427.08 | 13899.06 | 0.0313 | 0.32 | 18.13 |
| zigexec | 445.14 | 587.86 | 14333.08 | 13842.46 | 0.0313 | 0.73 | 22.25 |
| libxev | 143.43 | 269.10 | 14198.99 | 13961.92 | 0.0469 | 0.40 | 3.90 |
| zio | 704.07 | 1187.53 | 14104.48 | 12574.06 | 0.0274 | 2.38 | 26.59 |
