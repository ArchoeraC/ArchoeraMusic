# Scanner 去 async 重构 · 吞吐基线对比

> 日期 2026-09-10 · 语料 1000 个小文件（flac/aac/mp3 轮转，各 0.6s）· 并行度 8 · headless（stdout/stderr 丢弃）· 预热一次后正式测一次。
> 旧版 = `0a24c9cd`（Channel<Action>+Task 写循环 + Parallel.ForEachAsync）；新版 = 去 async（BlockingCollection+专用写线程 + Parallel.For + 同步 Scan）。

| 版本 | wall ms | files/s | user+sys s | 峰值 RSS MB | DB MB | WAL MB | tracks 行 | rc |
|---|---|---|---|---|---|---|---|---|
| 旧版(Channel+async) | 151 | 6619.2 | 0.26 | 68.8 | 0.5 | 0.0 | 1000 | 0 |
| 新版(去async) | 138 | 7260.7 | 0.20 | 66.8 | 0.5 | 0.0 | 1000 | 0 |

**对比**：wall 变化 **-8.8%**（151→138 ms）；files/s **6619.2→7260.7**（1.1×）；CPU 0.26→0.20 s；峰值 RSS 68.8→66.8 MB。

> 注：单次墙钟，含 dotnet 进程启动（~50-100ms）；files/s 受小文件主导（解析/写占比），真实大文件与纯 tag 扫描趋势另测。跨机请比相对变化。
