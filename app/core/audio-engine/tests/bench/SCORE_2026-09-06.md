# EraAudio 行业对比基准与评分（scorecard.py 自动汇总）

- 生成: 2026-09-05 23:07:30   构建快照: `2026-09-06`
- 引擎: `/home/betastudio2/文档/SPlayer-Next/ArchoeraMusic/app/core/audio-engine/build/archoera-audio-engine`   语料: `/tmp/eng2`
- 工具: ffmpeg n9.0.1 Copyright (c) 2000-2026 the FFmpeg developers / flac 1.5.0 / LAME 64bits version 4.0 (https://lame.sourceforge.io) / speexdec 1.2.1
- 引擎行 = `--player-file` 解码→float32 PCM（skip encoder，不重编码）；CLI 行 = 解码→s16。
- 权重: speed 40 / memory 30 / correctness 20 / coverage 10。
- 阈值: speed 40·min(1,R/50)(R=实时倍数)；memory 相对各引擎最小 RSS 平台值 (≤+3/10/25/60MB→30/26/20/12)；correctness lossless 逐位=满分、lossy len≤0.1% 且 |corr|≥0.999=满分（反号不可闻按 |corr|）。

## 1. 每格式 × 每引擎 综合得分

| 格式 | EraAudio(mode1) | Stable(mode0/FFmpeg) | ffmpeg CLI | flac -d | lame --decode | ffmpeg(libopus) | ffmpeg(libvorbis) | ffmpeg(libspeex) | speexdec |
|---|---|---|---|---|---|---|---|---|---|
| flac | 100.0(A+) | 100.0(A+) | 100.0(A+) | 100.0(A+) | — | — | — | — | — |
| wav | 100.0(A+) | 100.0(A+) | 100.0(A+) | — | — | — | — | — | — |
| wv | 100.0(A+) | 100.0(A+) | 100.0(A+) | — | — | — | — | — | — |
| tta | 82.0(B) | 96.0(A+) | 90.0(A) | — | — | — | — | — | — |
| mka(flac轨) | 100.0(A+) | 100.0(A+) | 96.0(A+) | — | — | — | — | — | — |
| mp3 | 100.0(A+) | 96.0(A+) | 96.0(A+) | — | 100.0(A+) | — | — | — | — |
| opus | 100.0(A+) | 100.0(A+) | 100.0(A+) | — | — | 100.0(A+) | — | — | — |
| vorbis | 100.0(A+) | 100.0(A+) | 100.0(A+) | — | — | — | 100.0(A+) | — | — |
| aac(m4a) | 100.0(A+) | 96.0(A+) | 96.0(A+) | — | — | — | — | — | — |
| aac(adts) | 100.0(A+) | 96.0(A+) | 96.0(A+) | — | — | — | — | — | — |
| ac3 | 92.0(A) | 100.0(A+) | 100.0(A+) | — | — | — | — | — | — |
| eac3 | 92.0(A) | 100.0(A+) | 96.0(A+) | — | — | — | — | — | — |
| dts | 82.0(B) | 96.0(A+) | 100.0(A+) | — | — | — | — | — | — |
| mp2 | 100.0(A+) | 96.0(A+) | 96.0(A+) | — | — | — | — | — | — |
| speex | 88.0(B) | 88.0(B) | 88.0(B) | — | — | — | — | 100.0(A+) | 80.0(B) |

## 2. 自研内核总体得分（对 FFmpeg 归一）

| 引擎 | 平均 speed(40) | 平均 memory(30) | 平均 correctness(20) | 平均 coverage(10) | 平均总分 |
|---|---|---|---|---|---|
| EraAudio(mode1) | 40.0 | 27.6 | 18.1 | 10.0 | 95.7 |
| Stable(mode0/FFmpeg) | 40.0 | 28.4 | 19.2 | 10.0 | 97.6 |
| ffmpeg CLI | 40.0 | 27.7 | 19.2 | 10.0 | 96.9 |
| flac -d | 40.0 | 30.0 | 20.0 | 10.0 | 100.0 |
| lame --decode | 40.0 | 30.0 | 20.0 | 10.0 | 100.0 |
| ffmpeg(libopus) | 40.0 | 30.0 | 20.0 | 10.0 | 100.0 |
| ffmpeg(libvorbis) | 40.0 | 30.0 | 20.0 | 10.0 | 100.0 |
| ffmpeg(libspeex) | 40.0 | 30.0 | 20.0 | 10.0 | 100.0 |
| speexdec | 40.0 | 30.0 | 0.0 | 10.0 | 80.0 |

**归一结论**：EraAudio 平均总分 95.7（A+） vs Stable/FFmpeg 97.6（A+） → 相对 FFmpeg = **98.1%**（Δ-1.9 分）

## 3. 原始关键测量（wall 秒 / ×RT / RSS MB / 帧数对齐）

| 格式 | 引擎 | ×RT | wall(s) | RSS(MB) | 帧数 | 参考帧数 | corr | bit-exact | 得分 |
|---|---|---|---|---|---|---|---|---|---|
| flac | EraAudio(mode1) | 0.00307 | 0.6147 | 29.3 | 8820000 |  |  | yes | 100.0 |
| flac | Stable(mode0/FFmpeg) | 0.00107 | 0.2144 | 34.6 | 8820000 |  |  | yes | 100.0 |
| flac | ffmpeg CLI | 0.00057 | 0.1141 | 51.1 | 8820000 |  |  | yes | 100.0 |
| flac | flac -d | 0.00082 | 0.1648 | 5.3 | 8820000 |  |  | yes | 100.0 |
| wav | EraAudio(mode1) | 0.00057 | 0.1142 | 27.8 | 8820000 |  |  | yes | 100.0 |
| wav | Stable(mode0/FFmpeg) | 0.00032 | 0.0642 | 33.2 | 8820000 |  |  | yes | 100.0 |
| wav | ffmpeg CLI | 0.00032 | 0.0644 | 50.9 | 8820000 |  |  | yes | 100.0 |
| wv | EraAudio(mode1) | 0.00333 | 0.6651 | 27.9 | 8820000 |  |  | yes | 100.0 |
| wv | Stable(mode0/FFmpeg) | 0.00282 | 0.5649 | 32.8 | 8820000 |  |  | yes | 100.0 |
| wv | ffmpeg CLI | 0.00082 | 0.1647 | 51.8 | 8820000 |  |  | yes | 100.0 |
| tta | EraAudio(mode1) | 0.00207 | 0.4148 | 54.1 | 8820000 |  |  | yes | 82.0 |
| tta | Stable(mode0/FFmpeg) | 0.00157 | 0.3145 | 35.7 | 8820000 |  |  | yes | 96.0 |
| tta | ffmpeg CLI | 0.00057 | 0.1146 | 67.4 | 8820000 |  |  | yes | 90.0 |
| mka(flac轨) | EraAudio(mode1) | 0.00383 | 0.7654 | 29.1 | 8820000 |  |  | yes | 100.0 |
| mka(flac轨) | Stable(mode0/FFmpeg) | 0.00107 | 0.2145 | 32.9 | 8820000 |  |  | yes | 100.0 |
| mka(flac轨) | ffmpeg CLI | 0.00057 | 0.1146 | 52.8 | 8820000 |  |  | yes | 96.0 |
| mp3 | EraAudio(mode1) | 0.00132 | 0.2644 | 28.3 | 8820000 | 8820000 | 1.0 |  | 100.0 |
| mp3 | Stable(mode0/FFmpeg) | 0.00082 | 0.1643 | 35.5 | 8820000 | 8820000 | 1.0 |  | 96.0 |
| mp3 | ffmpeg CLI | 0.00107 | 0.2146 | 53.1 | 8820000 | 8820000 | 1.0 |  | 96.0 |
| mp3 | lame --decode | 0.00108 | 0.2151 | 6.3 | 8820000 | 8820000 | 1.0 |  | 100.0 |
| opus | EraAudio(mode1) | 0.00232 | 0.4647 | 28.5 | 9600000 | 9600000 | 0.999335 |  | 100.0 |
| opus | Stable(mode0/FFmpeg) | 0.00157 | 0.3149 | 33.2 | 9600000 | 9600000 | 1.0 |  | 100.0 |
| opus | ffmpeg CLI | 0.00158 | 0.3153 | 49.2 | 9600000 | 9600000 | 1.0 |  | 100.0 |
| opus | ffmpeg(libopus) | 0.00207 | 0.4147 | 52.4 | 9600000 | 9600000 | 1.0 |  | 100.0 |
| vorbis | EraAudio(mode1) | 0.00107 | 0.2141 | 28.6 | 8820000 | 8820000 | 1.0 |  | 100.0 |
| vorbis | Stable(mode0/FFmpeg) | 0.00057 | 0.1142 | 33.3 | 8820000 | 8820000 | 1.0 |  | 100.0 |
| vorbis | ffmpeg CLI | 0.00082 | 0.1646 | 50.1 | 8820000 | 8820000 | 1.0 |  | 100.0 |
| vorbis | ffmpeg(libvorbis) | 0.00132 | 0.2647 | 52.2 | 8820000 | 8820000 | 1.0 |  | 100.0 |
| aac(m4a) | EraAudio(mode1) | 0.00157 | 0.3144 | 29.4 | 8820000 | 8820000 | 1.0 |  | 100.0 |
| aac(m4a) | Stable(mode0/FFmpeg) | 0.00082 | 0.1642 | 36.4 | 8820000 | 8820000 | 1.0 |  | 96.0 |
| aac(m4a) | ffmpeg CLI | 0.00082 | 0.1648 | 52.3 | 8820000 | 8820000 | 1.0 |  | 96.0 |
| aac(adts) | EraAudio(mode1) | 0.0018 | 0.3647 | 28.4 | 8821760 | 8821760 | 1.0 |  | 100.0 |
| aac(adts) | Stable(mode0/FFmpeg) | 0.00056 | 0.114 | 36.1 | 8821760 | 8821760 | 1.0 |  | 96.0 |
| aac(adts) | ffmpeg CLI | 0.00081 | 0.1645 | 53.0 | 8821760 | 8821760 | 1.0 |  | 96.0 |
| ac3 | EraAudio(mode1) | 0.00132 | 0.2645 | 28.6 | 8821248 | 8821248 | 0.964139 |  | 92.0 |
| ac3 | Stable(mode0/FFmpeg) | 0.00082 | 0.1642 | 35.3 | 8821248 | 8821248 | 1.0 |  | 100.0 |
| ac3 | ffmpeg CLI | 0.00082 | 0.165 | 52.1 | 8821248 | 8821248 | 1.0 |  | 100.0 |
| eac3 | EraAudio(mode1) | 0.00132 | 0.2645 | 28.6 | 8821248 | 8821248 | 0.962835 |  | 92.0 |
| eac3 | Stable(mode0/FFmpeg) | 0.00082 | 0.1648 | 35.3 | 8821248 | 8821248 | 1.0 |  | 100.0 |
| eac3 | ffmpeg CLI | 0.00082 | 0.1641 | 52.7 | 8821248 | 8821248 | 1.0 |  | 96.0 |
| dts | EraAudio(mode1) | 0.00207 | 0.4149 | 83.4 | 8820224 | 8820224 | 1.0 |  | 82.0 |
| dts | Stable(mode0/FFmpeg) | 0.00107 | 0.2149 | 35.6 | 8820224 | 8820224 | 1.0 |  | 96.0 |
| dts | ffmpeg CLI | 0.00107 | 0.2148 | 51.8 | 8820224 | 8820224 | 1.0 |  | 100.0 |
| mp2 | EraAudio(mode1) | 0.00107 | 0.2141 | 28.0 | 8820864 | 8820864 | 1.0 |  | 100.0 |
| mp2 | Stable(mode0/FFmpeg) | 0.00082 | 0.1641 | 37.3 | 8820864 | 8820864 | 1.0 |  | 96.0 |
| mp2 | ffmpeg CLI | 0.00082 | 0.1644 | 53.8 | 8820864 | 8820864 | 1.0 |  | 96.0 |
| speex | EraAudio(mode1) | 0.00057 | 0.1141 | 27.5 | 3200000 | 3200000 | 0.931742 |  | 88.0 |
| speex | Stable(mode0/FFmpeg) | 0.00082 | 0.1642 | 32.4 | 3200000 | 3200000 | 0.931741 |  | 88.0 |
| speex | ffmpeg CLI | 0.00082 | 0.1642 | 50.2 | 3200000 | 3200000 | 0.931742 |  | 88.0 |
| speex | ffmpeg(libspeex) | 0.00082 | 0.1646 | 51.6 | 3200000 | 3200000 | 1.0 |  | 100.0 |
| speex | speexdec | 0.00057 | 0.1141 | 2.8 | 3199777 | 3200000 | -0.144834 |  | 80.0 |

## 4. 参考面与未覆盖项说明（诚实记录）

- **opus**：无独立 opusdec，以 ffmpeg 内嵌 libopus 为参考（与 engine-integration-bench §6 一致）
- **vorbis**：无独立 oggdec，以 ffmpeg 内嵌 libvorbis 为参考
- **wv**：无独立 wvunpack，以 ffmpeg 内嵌 wavpack 解码为参考
- **tta**：无独立 CLI，以 ffmpeg 内嵌 tta 解码为参考
- **aac(m4a)**：无独立 aac 参考（libaac 非解码器），以 ffmpeg native aac 为参考
- **aac(adts)**：无独立 aac 参考，以 ffmpeg native aac 为参考
- **ac3**：无独立 CLI，以 ffmpeg native ac3 为参考
- **eac3**：无独立 CLI，以 ffmpeg native eac3 为参考
- **dts**：无独立 CLI，以 ffmpeg native dca 为参考
- **mp2**：无独立 CLI，以 ffmpeg native mp2 为参考
- **speex**：speexdec 存在但与 libspeex 族极性相反分歧 → 以 ffmpeg libspeex 为参考、按 |corr| 计分
- 其余小语种（ape/shn/tak/als/dst/mpc/wma/dsf/dff 等）未纳入本轮行业矩阵，以 `format-support-matrix.md` 为准；本轮聚焦播放器主流 15 轨。
- EraAudio 自研测量均为 `--engine-mode 1` 且 **native 接管**（takeover=原生），无回退；构建顺序 `zig build -Doptimize=ReleaseFast` → `cmake --build build`（ReleaseFast kernel）。

总耗时 45s。产物：`/home/betastudio2/文档/SPlayer-Next/ArchoeraMusic/app/core/audio-engine/tests/bench/data/SCORE_results.csv`。
