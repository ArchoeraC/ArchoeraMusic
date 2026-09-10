# ArchoeraMusic 统一能力检测（2026-09-10）

> `run_suite.py` 合并旧基准脚本：内核单测 + 引擎 ctest + 逐格式 scorecard + 池并发压力 + scanner 吞吐。数据可复现，跨机比相对值。

## A. 内核单测（zig build test）

- 结果：**633 passed**（rc=0，47.2s）

## B. 引擎 ctest

- 结果：**15 项，失败 0**（rc=0，4.5s）
- 用例：test_equalizer, test_limiter, test_fft, test_loudness, test_mediaengine_wait, test_native_seek, test_memory_mode, test_segstore, test_segpool, test_store_decode, test_store_pipeline, test_engine_pool, test_pool_pipeline, test_metadata_abi, test_random_seek

## C. 逐格式解码 scorecard（FFmpeg=100）

| 格式 | era wall(s) | era ×RT | era RSS(MB) | Stable wall(s) | era 得分 |
|---|---|---|---|---|---|
| flac | 0.566 | 0.00283 | 27.6 | 0.3322 | 100.0 |
| wav | 0.2153 | 0.00108 | 27.4 | 0.2324 | 100.0 |
| wv | 0.8165 | 0.00408 | 28.8 | 0.6493 | 100.0 |
| tta | 0.5156 | 0.00258 | 53.0 | 0.3822 | 82.0 |
| mka(flac轨) | 0.6659 | 0.00333 | 28.8 | 0.2821 | 100.0 |
| mp3 | 0.3489 | 0.00174 | 27.6 | 0.3155 | 100.0 |
| opus | 0.5657 | 0.00283 | 28.9 | 0.3149 | 100.0 |
| vorbis | 0.3487 | 0.00174 | 28.3 | 1.0168 | 100.0 |
| aac(m4a) | 0.349 | 0.00174 | 30.3 | 0.2489 | 96.0 |
| aac(adts) | 0.3818 | 0.00188 | 28.1 | 0.1982 | 100.0 |
| ac3 | 0.3655 | 0.00183 | 28.0 | 0.2649 | 92.0 |
| eac3 | 0.3321 | 0.00166 | 29.2 | 0.2654 | 92.0 |
| dts | 0.5158 | 0.00258 | 81.4 | 0.2986 | 82.0 |
| mp2 | 0.2985 | 0.00149 | 30.0 | 0.2655 | 100.0 |
| speex | 0.1815 | 0.00091 | 27.2 | 0.1814 | 88.0 |

- 总体均分：**era 95.5 vs stable 97.6 vs ffmpeg 95.9**（FFmpeg 归一=100）
- 公平性：speed=40·min(1,R/50) 在本语料饱和（≥50×RT），总分差异实际来自 memory/correctness；无损要求 era==stable==ffmpeg 逐位；每项 reps=5 去极值，核心 pin P 核（taskset 0-15）。

## D. 内核池并发压力（bench_era_pool，流上限=并发）

| N | 进程墙钟 ms | 峰值 RSS MB | files_ok | 合计帧 |
|---|---|---|---|---|
| 1 | 32 | 27.3 | 1/1 | 132300 |
| 2 | 34 | 29.4 | 2/2 | 264600 |
| 4 | 34 | 30.4 | 4/4 | 529200 |
| 8 | 38 | 33.2 | 8/8 | 1058400 |
| 16 | 47 | 38.9 | 16/16 | 2116800 |
| 32 | 63 | 49.8 | 32/32 | 4233600 |
| 64 | 84 | 61.8 | 64/64 | 8467200 |
| 128 | 93 | 85.0 | 128/128 | 16934400 |

- 流上限=并发（`zk_engine_init_streams(...,N)`）；**对照默认流上限 8、N=128：27/128**（证明默认会限制并发）。
- 本节为 era 单侧能力/内存口径，**无 FFmpeg 基线**；核心 pin P 核（0-15）降噪。

## E. scanner 元数据吞吐（1000 小文件）

| 并行度 | 引擎 | wall ms | 峰值 RSS MB | rc | tracks |
|---|---|---|---|---|---|
| 1 | kernel | 326 | 54.3 | 0 | 1000 |
| 1 | taglib | 358 | 54.4 | 0 | 1000 |
| 8 | kernel | 321 | 57.2 | 0 | 1000 |
| 8 | taglib | 308 | 57.2 | 0 | 1000 |
| 32 | kernel | 325 | 60.5 | 0 | 1000 |
| 32 | taglib | 283 | 60.1 | 0 | 1000 |
| 128 | kernel | 362 | 60.4 | 0 | 1000 |
| 128 | taglib | 361 | 60.2 | 0 | 1000 |

- 正确性对拍（par=8）：tracks kernel=1000 / taglib=1000；字段一致性：一致。

## 说明

- 逐格式 scorecard 语料为可复现音乐结构仿真；内核单测含逐格式解码 e2e（无损逐位/有损 corr 门）。
- 池压力用 `zk_engine_init_streams(...,N)` 放开流上限（默认 8 会限制并发）。
