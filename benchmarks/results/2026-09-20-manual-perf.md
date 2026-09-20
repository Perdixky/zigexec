# 64 B / 256 connections: perf stat per validated echo

Three 10-second trials per binary; 2-second warmup. Values are medians of normalized counters. Kernel counters include interrupt work charged during the task, not just process system CPU.

| Library | cycles:u | instructions:u | cycles:k | instructions:k | syscalls:sys_enter_io_uring_enter | branch-misses:u | cache-misses:u |
|---|---:|---:|---:|---:|---:|---:|---:|
| baseline | 953.61 | 1232.59 | 14320.17 | 13861.32 | 0.0313 | 0.42 | 32.41 |
| structured | 663.53 | 1047.98 | 14424.82 | 13917.51 | 0.0313 | 0.74 | 30.33 |
| zigexec | 557.43 | 869.73 | 14332.50 | 13752.45 | 0.0313 | 0.73 | 20.26 |
| libxev | 154.71 | 279.52 | 14321.15 | 13938.38 | 0.0469 | 0.43 | 4.05 |
| zio | 670.51 | 1186.40 | 14185.55 | 12589.92 | 0.0268 | 2.36 | 25.06 |
