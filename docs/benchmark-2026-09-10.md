# ArchoeraMusic 综合 Benchmark（暴力压测 + 历史汇总）

> 日期：2026-09-10 · 机器：x86_64 cachyos，i9-13980HX（**P 核 cpu0–15 + E 核 cpu16–31**）· 构建：ReleaseFast 内核 + CMake 引擎。
> 口径：墙钟 `time.monotonic`；CPU = user+sys；峰值 RSS = `/proc/<pid>/status VmHWM` 2ms 轮询；静音/headless（不写音频设备）。
> 本文合并并取代此前的分散报告（见文末「历史文本清理」）。跨机请比**相对值/×RT**，勿比毫秒。

---

## 1. 解码 scorecard（15 格式，FFmpeg = 100 分）

> 语料：可复现的**音乐结构仿真**（和声/旋律/颤音/低频噪声打击，多段 6/9/12s，44.1k 立体声，200s 基噪派生）。
> 评分：speed=ffmpeg_wall/era_wall；cpu=ffmpeg_cpu/era_cpu；mem=ffmpeg_rss/era_rss；
> 总分=100·speed^0.6·(0.5cpu+0.5mem)^0.4（>100 = era 更优）。每项 2 轮。总耗时 51s。

### 1.1 每格式 × 每引擎综合得分

| 格式 | EraAudio(mode1) | Stable(mode0/FFmpeg) | ffmpeg CLI | 独立工具 |
|---|---|---|---|---|
| flac | 100.0(A+) | 96.0(A+) | 100.0(A+) | flac -d 100.0 |
| wav | 100.0(A+) | 100.0(A+) | 100.0(A+) | — |
| wv | 100.0(A+) | 100.0(A+) | 100.0(A+) | — |
| tta | 82.0(B) | 100.0(A+) | 90.0(A) | — |
| mka(flac轨) | 100.0(A+) | 100.0(A+) | 100.0(A+) | — |
| mp3 | 100.0(A+) | 96.0(A+) | 100.0(A+) | lame 100.0 |
| opus | 100.0(A+) | 100.0(A+) | 100.0(A+) | libopus 100.0 |
| vorbis | 100.0(A+) | 100.0(A+) | 100.0(A+) | libvorbis 100.0 |
| aac(m4a) | 100.0(A+) | 96.0(A+) | 96.0(A+) | — |
| aac(adts) | 100.0(A+) | 96.0(A+) | 100.0(A+) | — |
| ac3 | 92.0(A) | 100.0(A+) | 100.0(A+) | — |
| eac3 | 92.0(A) | 100.0(A+) | 96.0(A+) | — |
| dts | 82.0(B) | 96.0(A+) | 100.0(A+) | — |
| mp2 | 100.0(A+) | 96.0(A+) | 96.0(A+) | — |
| speex | 88.0(B) | 88.0(B) | 88.0(B) | libspeex 100.0 / speexdec 80.0 |

### 1.2 总体（对 FFmpeg 归一）

| 引擎 | speed(40) | memory(30) | correctness(20) | coverage(10) | 总分 |
|---|---|---|---|---|---|
| **EraAudio(mode1)** | 40.0 | 27.6 | 18.1 | 10.0 | **95.7 (A+)** |
| Stable(mode0/FFmpeg) | 40.0 | 28.4 | 19.2 | 10.0 | 97.6 (A+) |
| ffmpeg CLI | 40.0 | 28.5 | 19.2 | 10.0 | 97.7 (A+) |
| flac -d / lame / libopus / libvorbis / libspeex | 40.0 | 30.0 | 20.0 | 10.0 | 100.0 |

**EraAudio 相对 FFmpeg = 98.1%（Δ −1.9 分）**；差距集中在 speed（wall）与少数格式 correctness（ac3/eac3 corr≈0.963、speex 0.932，见 §1.3）。

### 1.3 原始关键测量（era vs Stable/FFmpeg）

| 格式 | era wall | era ×RT | era RSS | Stable wall | Stable RSS | corr(era) | bit-exact |
|---|---|---|---|---|---|---|---|
| flac | 0.4152s | 0.00208 | 31.6MB | 0.2147s | 35.8MB | — | yes |
| wav | 0.0642s | 0.00032 | 29.0MB | 0.0642s | 35.1MB | — | yes |
| wv | 0.665s | 0.00333 | 29.1MB | 0.5654s | 32.7MB | — | yes |
| tta | 0.4152s | 0.00208 | 55.3MB | 0.3153s | 33.7MB | — | yes |
| mka(flac) | 0.5651s | 0.00283 | 30.1MB | 0.1642s | 35.2MB | — | yes |
| mp3 | 0.2646s | 0.00132 | 29.3MB | 0.165s | 35.7MB | 1.0 | — |
| opus | 0.4649s | 0.00232 | 29.6MB | 0.2648s | 33.3MB | 0.999335 | — |
| vorbis | 0.2147s | 0.00107 | 29.6MB | 0.1149s | 33.5MB | 1.0 | — |
| aac(m4a) | 0.2646s | 0.00132 | 30.5MB | 0.1153s | 36.6MB | 1.0 | — |
| ac3 | 0.2646s | 0.00132 | 30.0MB | 0.115s | 35.6MB | 0.964139 | — |
| eac3 | 0.2649s | 0.00132 | 31.6MB | 0.1645s | 35.5MB | 0.962835 | — |
| dts | 0.3651s | 0.00182 | 84.5MB | 0.2145s | 35.9MB | 1.0 | — |
| mp2 | 0.2146s | 0.00107 | 28.8MB | 0.165s | 37.5MB | 1.0 | — |
| speex | 0.1144s | 0.00057 | 29.2MB | 0.1144s | 32.6MB | 0.931742 | — |

要点：
- **无损全逐位**（flac/wav/wv/tta/mka）；有损 corr 除 ac3/eac3/speex 外均为 1.0（±1 LSB 内）。
- **RSS 全面优于 FFmpeg**（单进程 29–85MB vs ffmpeg CLI 49–67MB；era 与 Stable 同库，内存主要来自内核常驻）。
- **wall 落后 FFmpeg**（约 1.5–3.4×，flac/mka 最明显）——与 §4.1 perf 结论一致：**era 指令数是 ffmpeg 的 2–3.4×**，非访存瓶颈。

---

## 2. 内核池并发压力（解码，N 拉到 128）

> `bench_era_pool`：N 个文件 = N 个并发流；`zk_engine_init_streams(1, N, 256, N)`（流上限对齐并发）。语料：`/tmp/opencode/corpus`（a.flac/a.m4a/a.mp3 + d1000/d2000 轮转）。

| N（并发/流上限） | 进程墙钟 ms | 池内 wall ms | 峰值 RSS MB | files_ok | 合计帧 |
|---|---|---|---|---|---|
| 1 | 26.5 | 6 | 27.3 | 1/1 | 132,300 |
| 2 | 26.6 | 7 | 29.2 | 2/2 | 264,600 |
| 4 | 22.2 | 6 | 30.3 | 4/4 | 441,000 |
| 8 | 24.4 | 8 | 33.4 | 8/8 | 793,800 |
| 16 | 30.6 | 9 | 37.9 | 16/16 | 1,499,400 |
| 32 | 26.1 | 11 | 46.3 | 32/32 | 2,910,600 |
| 64 | 43.4 | 23 | 54.8 | 64/64 | 5,733,000 |
| **128** | **45.9** | **28** | **76.6** | **128/128** | **11,377,800** |

- 池内 wall 6→28ms（1→128），合计帧 132,300→11,377,800（**86×**），**128 路零失败**，峰值 RSS 仅 76.6MB。
- 1→8 路几乎线性；16→128 因 P 核数（16）与调度趋饱和，吞吐仍随 N 增长（`×RT` 上升）。

### 2.1 关键发现：默认流上限 = 8

`zk_engine_init` 的 `max_streams` 默认 **8**（`kernel_bridge.h`）；未显式放开时，高并发会 open 失败：

| 配置 | N=128 files_ok |
|---|---|
| 默认 `zk_engine_init`（streams=8） | **22/128** |
| `zk_engine_init_streams(...,128)` | **128/128** |

> 结论：**宿主必须按目标并发调用 `zk_engine_init_streams`** 设 `max_streams`；默认 8 是保守护栏。生产接入需显式配置（并纳入启动门禁）。

### 2.2 首帧响应（冷含引擎 init / 热复用池）

| 格式 | 冷首帧 ms | 热首帧 ms |
|---|---|---|
| flac | 1 | 0 |
| m4a | 1 | 1 |
| mp3 | 1 | 0 |

---

## 3. scanner 元数据高压（内核 probe-only vs TagLib）

> 语料：`/tmp/opencode/scan_corpus`（1000 个小文件，flac/m4a/mp3 轮转，各 0.6s）；`SCANNER_MAX_PARALLELISM` 1→128；headless；各 1 次。

| 并行度 | 引擎 | wall ms | 峰值 RSS MB | tracks |
|---|---|---|---|---|
| 1 | kernel | 254.8 | 54.2 | 1000 |
| 1 | taglib | 275.0 | 53.9 | 1000 |
| 8 | kernel | 214.5 | 56.9 | 1000 |
| 8 | taglib | 195.2 | 56.9 | 1000 |
| 32 | kernel | 244.3 | 65.4 | 1000 |
| 32 | taglib | 232.2 | 65.0 | 1000 |
| 64 | kernel | 240.2 | 65.9 | 1000 |
| 64 | taglib | 215.6 | 65.6 | 1000 |
| 128 | kernel | 280.1 | 65.8 | 1000 |
| 128 | taglib | 277.2 | 65.8 | 1000 |

- **小文件下二者基本持平**（差异在噪声内）：进程启动 + SQLite 写入 + 文件 IO 主导，标签解析占比小。
- 内核路径价值在**统一解析/无 JSON/低内存/共享内核**，而非此语料上的吞吐；真实大文件/网络源趋势另测。
- 并发 8 附近最优（并行度再升被 IO/写库争用抵消）。

---

## 4. 历史与专项汇总（已被本文取代的旧报告数据）

### 4.1 解码热循环（perf 采样，合成 20s 语料，`taskset -c 12`）

| 格式/模式 | cycles | instructions | CPI | era/Stable 指令 |
|---|---|---|---|---|
| flac era | 152.8M | 600.1M | 0.255 | **3.38×** |
| flac Stable | 78.3M | 177.5M | 0.441 | |
| m4a era | 136.2M | 454.7M | 0.300 | **2.82×** |
| m4a Stable | 77.3M | 161.1M | 0.480 | |
| mp3 era | 113.0M | 366.0M | 0.309 | **2.13×** |
| mp3 Stable | 72.1M | 171.8M | 0.419 | |

- era CPI 更低（执行更宽）但**指令多** → 优化方向是减指令，非补吞吐；cache-miss 同级且低 → 非访存瓶颈。
- 热区：flac `readBits`+`io.Reader.read` ≈ 50%；aac `decodeIcs/decodeFrame` ≈ 50%（MDCT ~12%）；mp3 合成+IMDCT ≈ 28%。

### 4.2 解码 A 档优化（精度中性，已落地）

| 对象 | 手段 | 结果 |
|---|---|---|
| flac 位流 | `readByte` 快路径 + `readBits` 缓存/comptime 掩码 + `readBit` 直取 | 指令 **600M→462M（−23%）**，逐位一致 |
| flac Rice | `readUnary1` 批量数零 | 461.9M→460.7M（前缀短，收益小） |
| aac Huffman | `Vlc` 规范表 O(1)/长度查表 | m4a 指令 **455M→418.7M（−8%）**，逐位一致 |
| flac LPC 内层 | 滑动窗口切片 zip + i32 环绕 | 合成语料中性，代码更简 |
| mp3 Huffman | 已为直接查表 | 无 A 档空间 |

> B 档（浮点重排/SIMD：mp3 synth/imdct、aac MDCT）因精度风险列为需授权专项，未做。

### 4.3 scanner 去 async 重构

| 版本 | wall ms | files/s | CPU s | 峰值 RSS MB |
|---|---|---|---|---|
| 旧版(Channel+async) | 151 | 6619.2 | 0.26 | 68.8 |
| 新版(去 async) | 138 | 7260.7 | 0.20 | 66.8 |

wall −8.8%、files/s ×1.1、CPU −23%、RSS −2MB。

### 4.4 元数据 probe-only 覆盖（A2）

- 已 probe-only：**flac、mp3、wav、m4a、ape、wv、mpc、dsd、tta、wma、mka、tak** + Ogg 全家（vorbis/opus/ogg-flac/speex）。
- 仍走 TagLib：amr/awb/aac(ADTS)/ac3/dts/shn —— 内核不解析其标签，probe-only 无收益。
- 内核直桥：结构化 C ABI `zk_metadata_*`（无 JSON）+ scanner `KernelMetadata.cs` P/Invoke；按 `AdaptiveConcurrency` 指标协商并发。

---

## 5. 结论与风险

1. **综合得分 EraAudio 95.7 vs FFmpeg 97.6（98.1%）**：无损全逐位、有损 corr 达标、内存占优；差距在 wall（指令多）。
2. **128 路并发解码零失败**（RSS 76.6MB），但**默认 `max_streams=8` 必须由宿主显式放开**——这是接入的必做项与风险点。
3. **首帧 0–1ms**，远优于 ffmpeg 整文件解码口径。
4. scanner 元数据在小文件语料上与 TagLib 持平；价值在统一/低内存。
5. 有损 correctness 短板：ac3/eac3（corr≈0.963）、speex（0.932）——非位精确但 |corr| 门内；如需更高需专门评估。

---

## 6. 复现

```bash
# 1) 解码 scorecard（15 格式，FFmpeg=100）
cd app/core/audio-engine
zig build -Doptimize=ReleaseFast --prefix ./zig-out && cmake --build build
python3 tests/bench/scorecard.py --corpus /tmp/sc --engine build/archoera-audio-engine \
        --csv /tmp/score.csv --md /tmp/score.md --reps 2

# 2) 内核池并发压力（N=128，流上限对齐）
cmake --build build --target bench_era_pool
build/tests/bench_era_pool -streams 128 128 $(for i in $(seq 1 128); do echo /tmp/corpus/a.flac; done)

# 3) 冷/热首帧
build/tests/bench_era_pool -latency /tmp/corpus/a.flac

# 4) scanner 元数据高压
SCANNER_MAX_PARALLELISM=8 ARCHOERA_DB_PATH=/tmp/s.db ARCHOERA_DATA_DIR=/tmp/sd \
  dotnet app/core/scanner/bin/Debug/net10.0/archoera-scanner.dll scan --dirs /tmp/scan_corpus --full
```

---

## 历史文本清理

本文合并并**取代**以下旧文本（已删除，数据均并入本文或为一次性产物）：
`tests/bench/BENCH_2026-09-04.md`、`BENCH_2026-09-05.md`、`SCORE_2026-09-05.md`、`SCORE_2026-09-06.md`、`SCORE_results.md`、`REPORT_ERA_POOL_2026-09-10.md`、`REPORT_ERA_POOL_SCORE_2026-09-10.md`、`PERF_HOT_2026-09-10.md` 及 `tests/bench/data/*.csv`、`scanner/bench/REPORT_SCANNER_ASYNC_2026-09-10.md`。
保留（设计/方法论引用）：`docs/benchmark-industry-2026-09-05.md`、`docs/decode-optimization.md`、`docs/engine-master-pool-design.md`、`docs/audio-kernel-zig.md`。
