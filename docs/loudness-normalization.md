# 响度归一化（ReplayGain / 离线分析）

> 2026-10-10 · 补齐「设置 → 音频效果 → 响度归一化」此前为**假开关**的半成品。

## 目标

统一各曲目回放响度，使跨曲目切换时音量一致。目标响度取 **−18 LUFS**
（ReplayGain 2.0 参考），使两条增益来源口径一致：

1. **文件内 ReplayGain 标签**（优先）：`REPLAYGAIN_TRACK_GAIN` /
   `REPLAYGAIN_ALBUM_GAIN`（及 Opus `R128_*_GAIN`，Q7.8 定点）。
2. **扫描器离线分析**（兜底）：对本地文件离线测量 EBU R128 集成响度，
   写入曲库 `tracks.loudness_lufs`（另存 `loudness_peak`）。

## 增益解析优先级（引擎侧）

`pipeline_apply_normalization()`（`app/core/audio-engine/src/pipeline.c`）：

1. 开关关闭 → 旁通；
2. 文件含标签：按口径取 `album`（`normalization_album=1`）或 `track` 增益，
   并**按峰值做削波保护**（限制 `peak · 10^(gain/20) ≤ 1`）；
3. 无标签 → 用调用方（Dart）下发的**兜底增益**（已由 Dart 预削波）；
4. 仍无 → 0 dB（等效不补偿，引擎自动关闭 loudness）。

> 自研内核（EraAudio 实验引擎）路径没有 FFmpeg `AVFormatContext`，
> 无法读写标签 → 仅用兜底增益；默认 Stable（FFmpeg）路径两条来源均可用。

## 引擎 ABI

- `EngineConfig` 新增 `normalization_album`（0=track / 1=album）；
  `normalization_gain` 语义为「兜底增益」（仅无标签时使用）。
- 运行时命令 `set_normalization { enabled, gain_db, album }`：
  先设兜底增益与口径，再设开关，最后一次 `apply` 用最终状态。
- 新增 `pipeline_set_normalization_gain()` / `pipeline_set_normalization_album()`。
- 标签读取：`decoder_replaygain()`（`decoder.c`，位掩码返回 track/album 的
  gain+peak 命中情况）。

## Dart 侧

- 偏好：`audio.normalization`（开关）/ `audio.normalization.album`（口径）。
- `normalizationGainDb()`（`prefs_audio_fx.dart`，纯函数、可测）：
  `gain = target(=−18) − lufs`，按峰值削波，收敛到 `[−60, +24] dB`。
- `applyAudioEffects()` 每次会话下发 `set_normalization`（含 `gain_db`/`album`），
  来源为当前曲目的 `Track.loudnessLufs` / `loudnessPeak`（本地离线分析结果）。

## 离线分析（扫描器）

- 内核：`zk_loudness_measure()`（EBU R128 / BS.1770-4，`kernel/dsp/loudness_measure.zig`）
  解码测量集成响度 + 线性采样峰值。
- 扫描器：`--analyze-loudness`（CLI）/ `analyzeLoudness`（FFI 选项）开启逐曲分析，
  写入曲库 `tracks.loudness_lufs` / `loudness_peak`（旧库自动 `ALTER TABLE` 迁移；
  增量扫描用 `COALESCE` 合并，不覆盖已分析值）。
- App 入口：设置 → 扫描 →「扫描时分析响度」（偏好 `scan.analyzeLoudness`），
  经 `scanner_set_options` 透传到引擎；默认关闭以免拖慢常规扫描。
  已入库曲目需**全量扫描**才会补测。
- 详见 `docs/local-library.md`。
