# ArchoeraMusic 统一能力检测（2026-09-10）

> `run_suite.py` 合并旧基准脚本：内核单测 + 引擎 ctest + 逐格式 scorecard + 池并发压力 + scanner 吞吐。数据可复现，跨机比相对值。

## A. 内核单测（zig build test）

- 结果：**633 passed**（rc=0，49.8s）

## B. 引擎 ctest

- 结果：**16 项，失败 0**（rc=0，14.9s）
- 用例：test_equalizer, test_limiter, test_fft, test_loudness, test_mediaengine_wait, test_native_seek, test_memory_mode, test_segstore, test_segpool, test_store_decode, test_store_pipeline, test_engine_pool, test_pool_pipeline, test_metadata_abi, test_random_seek, test_random_seek_mp3

## C. 逐格式解码 scorecard（FFmpeg=100）

| 格式 | era wall(s) | era ×RT | era RSS(MB) | Stable wall(s) | era 得分 |
|---|---|---|---|---|---|
| flac | 0.5333 | 0.00267 | 29.1 | 0.3487 | 100.0 |
| wav | 0.1982 | 0.00099 | 27.4 | 0.182 | 100.0 |
| wv | 0.7168 | 0.00358 | 27.3 | 0.5654 | 100.0 |
| tta | 0.5156 | 0.00258 | 53.0 | 0.4158 | 82.0 |
| mka(flac轨) | 0.6156 | 0.00308 | 28.8 | 0.2992 | 100.0 |
| mp3 | 0.3655 | 0.00183 | 27.4 | 0.2486 | 100.0 |
| opus | 0.5494 | 0.00275 | 28.1 | 0.3826 | 100.0 |
| vorbis | 0.2821 | 0.00141 | 28.1 | 0.2652 | 100.0 |
| aac(m4a) | 0.3489 | 0.00174 | 28.6 | 0.2151 | 100.0 |
| aac(adts) | 0.3822 | 0.00188 | 28.0 | 0.2491 | 100.0 |
| ac3 | 0.3484 | 0.00174 | 28.1 | 0.1815 | 92.0 |
| eac3 | 0.3491 | 0.00174 | 29.0 | 0.2822 | 92.0 |
| dts | 0.5161 | 0.00258 | 81.7 | 0.2987 | 82.0 |
| mp2 | 0.2986 | 0.00149 | 27.6 | 0.2991 | 100.0 |
| speex | 0.2152 | 0.00108 | 27.2 | 0.2152 | 88.0 |

- 总体均分：**era 95.7 vs stable 97.9 vs ffmpeg 96.7**（FFmpeg 归一=100）
- 公平性：speed=40·min(1,R/50) 在本语料饱和（≥50×RT），总分差异实际来自 memory/correctness；无损要求 era==stable==ffmpeg 逐位；每项 reps=5 去极值，核心 pin P 核（taskset 0-15）。

## D. 内核池并发压力（bench_era_pool，流上限=并发）

| N | 进程墙钟 ms | 峰值 RSS MB | files_ok | 合计帧 |
|---|---|---|---|---|
| 1 | 36 | 27.7 | 1/1 | 132300 |
| 2 | 34 | 29.1 | 2/2 | 264600 |
| 4 | 37 | 30.4 | 4/4 | 529200 |
| 8 | 44 | 33.4 | 8/8 | 1058400 |
| 16 | 46 | 38.4 | 16/16 | 2116800 |
| 32 | 59 | 49.3 | 32/32 | 4233600 |
| 64 | 72 | 64.8 | 64/64 | 8467200 |
| 128 | 68 | 83.0 | 128/128 | 16934400 |

- 流上限=并发（`zk_engine_init_streams(...,N)`）；**对照默认流上限 8、N=128：24/128**（证明默认会限制并发）。
- 本节为 era 单侧能力/内存口径，**无 FFmpeg 基线**；核心 pin P 核（0-15）降噪。

## E. scanner 元数据吞吐（1000 小文件）

| 并行度 | 引擎 | wall ms | 峰值 RSS MB | rc | tracks |
|---|---|---|---|---|---|
| 1 | kernel | 333 | 54.4 | 0 | 1000 |
| 1 | taglib | 327 | 54.4 | 0 | 1000 |
| 8 | kernel | 306 | 57.2 | 0 | 1000 |
| 8 | taglib | 321 | 57.3 | 0 | 1000 |
| 32 | kernel | 280 | 60.3 | 0 | 1000 |
| 32 | taglib | 283 | 60.3 | 0 | 1000 |
| 128 | kernel | 301 | 60.3 | 0 | 1000 |
| 128 | taglib | 296 | 60.4 | 0 | 1000 |

- 正确性对拍（par=8）：tracks kernel=1000 / taglib=1000；字段一致性：一致。

## 说明

- 逐格式 scorecard 语料为可复现音乐结构仿真；内核单测含逐格式解码 e2e（无损逐位/有损 corr 门）。
- 池压力用 `zk_engine_init_streams(...,N)` 放开流上限（默认 8 会限制并发）。
