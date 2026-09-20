# TCP echo benchmark

Medians across independent trials. RPS counts complete validated echoes; MiB/s counts payload in one direction. p50/p99 are medians of each trial's RTT percentiles (1 µs histogram buckets).

| Bytes | Connections | Library | Echoes/s | Min–max | MiB/s | p50 µs | p99 µs | Server CPU % | CPU µs/echo | RSS MiB |
|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 64 | 256 | baseline | 339,545 | 336,280–340,215 | 20.7 | 748 | 913 | 66.7 | 1.96 | 3.0 |
| 64 | 256 | libxev | 345,781 | 340,359–347,710 | 21.1 | 727 | 974 | 65.3 | 1.90 | 1.6 |
| 64 | 256 | zigexec | 340,128 | 338,778–342,176 | 20.8 | 740 | 966 | 66.3 | 1.94 | 3.0 |
| 64 | 256 | zio | 339,677 | 338,702–340,143 | 20.7 | 744 | 935 | 66.0 | 1.94 | 5.4 |
| 4096 | 32 | baseline | 317,372 | 307,762–318,796 | 1239.7 | 98 | 142 | 65.0 | 2.05 | 1.3 |
| 4096 | 32 | libxev | 317,070 | 313,365–326,128 | 1238.6 | 99 | 135 | 63.7 | 2.00 | 0.9 |
| 4096 | 32 | zigexec | 308,179 | 308,130–327,551 | 1203.8 | 101 | 142 | 64.7 | 2.09 | 1.2 |
| 4096 | 32 | zio | 286,025 | 278,186–287,597 | 1117.3 | 110 | 152 | 66.7 | 2.34 | 3.7 |
