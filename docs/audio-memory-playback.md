# 内存播放（不落盘）模式 — 设计规格与验收

> 状态：**规划定稿 · S1（C 引擎）与 S2（Dart 接线/pref/设置）已实现（2026-09-08 落地）；S3 基准与文档收尾待办**
>
> 范围：桌面端 `archoera-audio-engine`（`mediaengine_lib.c` / `audio_engine.h` /
> `archoera_mediaengine.h`）播放层新增「内存播放」能力；Dart 播放层（`engine_bindings.dart` /
> `pcm_analyzer.dart` / `audio_engine_process.dart` / `playback_notifier.dart`）配套改造。
>
> 关联：`docs/architecture.md` §5/§9/§10.1、`docs/audio-kernel-zig.md` P5/§15/§16.2。

## 1. 动机与目标语义

现状（player 模式）无论 `Stable`（FFmpeg）还是 `EraAudio`（Zig 内核），解码 PCM 都
**整曲写盘**：`on_pcm_out`（`mediaengine_lib.c`）把 PCM 同时写 `stream.wav` + `stream.pcm`
（流式喂设备与写盘并行），`stream.wav` 供 miniaudio 文件自播/回退，`stream.pcm` 供 Dart
`PcmAnalyzer` 拉模式做频谱。

「内存播放」模式的目标：**播放会话的解码产物全部驻留进程内内存，不写任何会话文件**——
流式出声照常；频谱可视化改走内存缓冲 + 新 FFI 拉取。仅当 **raw 设备流式无法启动**时按
用户设定直接报错（见 §5.1），不再回退写盘。

用户开关：
- **「内存播放（不落盘解码）」（`engineMemoryPlay`）默认开启**（独立于引擎 Stable/EraAudio
  选择）。
- 与「歌曲磁盘缓存（SongCache）」相互独立：前者约束引擎解码产物，后者约束在线源是否
  下载缓存文件。两者都关/开组合语义：
  | SongCache | 内存播放 | 效果 |
  |---|---|---|
  | 开 | 开 | 在线源照常落缓存文件；引擎不写 `stream.wav/.pcm` |
  | 开 | 关 | 现状：引擎写会话文件（文件模式） |
  | 关 | 开 | 在线源不落缓存、引擎不落盘（全程内存） |
  | 关 | 关 | 在线源不落缓存；引擎写会话文件（文件模式） |

> 文件模式（`engineMemoryPlay=false` 或 env `ARCHOERA_ENGINE_FILE_MODE=1`）：完全保留现状
> 行为（写 `stream.wav`/`stream.pcm`），字节级不变（含 PARITY 基准）。

## 2. EngineConfig 扩展

`app/core/audio-engine/include/audio_engine.h` `EngineConfig` 末尾追加（结构 append，Dart
`EngineConfigC` 同步加字段）：

```c
int no_disk_cache;     /* 1 = 内存播放模式（不写 stream.wav/.pcm）；默认随 Dart 开关 */
int64_t pcm_mem_cap_kb;/* PCM 内存保留上限（KB）：
                          0  = 自动（按可用内存均衡，含 0.8 GiB 硬上限，见 §3.3）
                          >0 = 用户指定上限（引擎绝不越过该值）
                          -1 = 无上限（整曲可回访任意已解码位置；设置须显式警告） */
```

`ENGINE_CONFIG_DEFAULT` 相应补默认（`no_disk_cache = 0` 作为 C 层默认，实际默认由 Dart 开关
注入；`pcm_mem_cap_kb = 0` 自动）。

## 3. 内存 PCM 存储（全量块列表 + 保留策略）

### 3.1 表示：与 `stream.pcm` 文件同构的块列表

```
BlockList {
    vector<Block> blocks;     /* {pos_ms:int32, frames:int32, channels:int32,
                                 float data[frames*channels]} —— 与文件块头格式一致 */
    int64  total_samples;     /* 全局样本游标（跨块累积） */
    size_t bytes;             /* 已驻留字节（cap 判定用） */
    int    session_epoch;     /* seek 重建即 +1，Dart/调用方可感知旧缓冲失效 */
}
```

- `on_pcm_out` 在 `no_disk_cache=1` 时不 `fwrite`，改 append 块并更新游标；
- seek / `mediaengine_stream_rebuild` 重建会话时**整表清空 + `session_epoch++`**
  （对齐现文件「截断重建 stream.pcm」语义，mediaengine_lib.c rebuild 同点）；
- destroy 随 handle 释放。

### 3.2 保留策略（二选一，由 cap 决定）

| cap | 策略 | 语义 |
|---|---|---|
| 全量块列表 | 解码多少存多少，**任意已解码位置可取帧** | 等价旧文件语义（内存版）；内存随播放时长线性增长 |
| 达 cap 后滚动淘汰 | 仅当 `bytes > cap` 时从队头逐最旧，保持有界 | 内存有界；仅损失「播放头之前的旧视窗」，实时可视化不受影响（日志提示一次 `retention degraded`） |

> 两种策略建立在**同一块列表表示**上，差别只在是否到 cap 后淘汰：
> - `cap=-1` ⇒ 全量块列表直至歌曲结束（用户显式选择，设置需警告，§4）；
> - `cap=auto/自定义` ⇒ 先全量存，到 cap 才退化滚动——默认即可回访任意已解码位置，直到
>   内存预算告警才降级。

### 3.3 自动 cap 计算与硬性封顶（`pcm_mem_cap_kb=0`）

引擎启动按当前**可用内存**均衡（复用 scraper `detectParallelism` 同款读取：Linux
`/proc/meminfo MemAvailable` / macOS `sysconf(_SC_AVPHYS_PAGES)` / Windows
`GlobalMemoryStatusEx`）：

```
floor = max(32MB, 2×解码前瞻 + fftSize 余量)
cap   = clamp(可用内存 × 0.1, floor, 0.8 GiB)
```

**硬性上限（0.8 GiB，不只停留在公式层，运行时强制）**：
- **0.8 GiB 是自动模式不可逾越的封顶**：无论可用内存查询返回多大、比例计算如何放大、
  或后续记账/解码批次出现超量，cap 都不超过 0.8 GiB；
- **计算故障回退**：可用内存查询失败或返回异常值 → 直接回落保守默认（≤0.8 GiB 的下限档），
  绝不因“拿不到数值”而放大上限；
- **超量强制**：每 append 一块后校验 `bytes > cap` → 立即自队头逐最旧直至 `≤ cap`
  （防“整批写入/记账偏斜”瞬时越过 cap）；
- **用户优先**：若用户设置了上限（`pcm_mem_cap_kb > 0`），有效 cap = 用户值，引擎**绝不越过**
  用户设定（也不再套用 0.8 GiB——显式选择且已警告）；`-1` 无上限同理须显式警告。auto 仅在用户
  未显式设限时生效。

解码速率参考（供用户/设置估算）：48kHz · 双声道 · f32 ≈ **0.38 MB/秒**。

## 4. 用户设置与显式警告（Dart）

设置页「播放」新增小组（`app/lib/settings/settings_sections/settings_sections_playback.dart`，
prefs 见 `app/lib/stores/prefs_player.dart`）：

- 开关「内存播放（不写磁盘解码缓存）」，**默认开**，对下一首生效（会话级，无需重启应用）。
- 缓冲策略下拉：`自动（按可用内存均衡）` / `指定上限 (MB 输入)` / `无上限`。
- 选择**无上限**（或输入极大值 ≥4GB）→ 显式确认对话框，文案必须明示后果：
  解码 PCM ≈ 0.38 MB/秒（48kHz·2ch·f32），长曲/长会话可累积数百 MB~GB，可能造成：
  应用被系统回收（内存压力）、拖慢整机、极端下系统不稳定/无响应。确认后才生效。
- 策略映射到 `pcm_mem_cap_kb`：自动=0；自定义=MB×1024；无上限=-1。

## 5. 引擎/FFI 变更

### 5.1 无设备 + 内存模式 → 直接 error（不做文件回退）

`mediaengine_stream_begin`（`mediaengine_lib.c`）失败且 `no_disk_cache=1`：**不走**旧
「全速解码→文件→miniaudio」回退，emit：

```json
{"type":"error","message":"内存播放模式无可用输出设备"}
```

随后正常收尾（flush → exited），会话目录不产生任何文件。

### 5.2 流式路径不再写文件

`engine_thread` 与 `mediaengine_stream_rebuild` 在 `no_disk_cache=1` 且流式成功时不调用
`wav_begin()` / `fopen(stream.pcm)`；`on_pcm_out` 改写入内存块列表 + 喂设备 ring。

### 5.3 新 FFI（append，不破坏既有符号）

```
int  archoera_mediaengine_pcm_window(ArchoeraMediaEngine *e,
                                     int end_pos_ms, int frames,
                                     float *out_l, float *out_r);
/*  0  命中：以 end_pos_ms 为终点取最近 frames 样本（L/R，引擎输出恒 2ch）
 * -1  越出保留窗 / 尚未解码（调用方按现「帧缺失」处理，如频谱静默）
 * -2  参数错误 / 非内存模式会话（返回 -2 表示应走原文件路径） */
int  archoera_mediaengine_pcm_epoch(ArchoeraMediaEngine *e);
/* seek 重建后 epoch+1；Dart 据此丢弃旧缓存帧索引 */
```

调用语义与现 `PcmAnalyzer.frameAt`（二分块索引 + 跨块取窗 + 下混）一致；引擎输出已为
`cfg.output_channels`（2），FFI 直接给 L/R。

## 6. Dart 配套

- `EngineConfigC`（`engine_bindings.dart`）追加 `noDiskCache` / `pcmMemCapKb` 两字段；
  create 传入。
- `PcmAnalyzer` 拆双后端，`frameAt` 接口不变：
  - `FilePcmAnalyzer`（现状，文件模式）；
  - `MemoryPcmAnalyzer`（内存模式）：帧索引本地缓存；每次 frameAt 校验 epoch，命中拉
    `pcm_window`，miss 按静默；无需 `scan` 文件增量扫描。
- `playback_notifier.dart` 按开关选择实例；设置默认内存模式。
- 在线源行为不变（SongCache 开关独立，见 §1 组合表）。

## 7. 文件模式强制入口（基准/测试）

- 设置 `engineMemoryPlay=false`；
- 或 env `ARCHOERA_ENGINE_FILE_MODE=1`（Dart 启动注入 `no_disk_cache=0`）。

文件模式为字节级现状（PARITY SHA 基准在文件模式下执行）；内存模式默认下，基准/回归按
`pcm_window` 窗口比对（float 误差 ≤1e-4），不再比对文件。

## 8. 验收标准

1. `tests/test_memory_mode.c`：
   - 内存模式（含中途 seek / 暂停续播 / destroy）：会话目录**不产生** `stream.wav/.pcm`；
   - `ARCHOERA_ENGINE_FILE_MODE=1`：写盘与现状逐字节一致；
   - 无设备场景：emit error 且不落盘；
   - `pcm_window`：0/-1/-2 语义；`cap=auto` 边界、`cap=-1` 全量可回访、达 cap 滚动淘汰
     行为；seek 重建后 epoch+1 且旧帧不可再取；
   - **cap 强制不越界**：auto 模式注入“内存查询超大/查询失败”用例 → 实际 cap 仍 ≤0.8 GiB
     （失败回落下限档）；伪造音频超量批次 → append 后记账立即淘汰、不越过 cap；
     `pcm_mem_cap_kb>0` → 实测绝不越过用户值。
2. Dart 单元/集成：MemoryPcmAnalyzer 与 FilePcmAnalyzer 窗口样本误差 ≤1e-4；设置默认开；
   无上限确认框与文案出现；三档策略映射正确。
3. 回归：文件模式（env 强制）下既有引擎测试与 PARITY 基准全绿。
4. POSIX 编译 + C 测试通过；Windows 留 CI（沿用既有 `#ifdef _WIN32` 与 UTF-8 宽字符边界
   约定）。
5. RSS 有界性：auto 模式长播 RSS 增量有界且**实测不超过 0.8 GiB**（含查询故障/超量用例）；
   用户设限时不越过用户值；`cap=-1` 用户显式知悉（含警告）。

## 9. 分阶段实施

- **S1** C 引擎：EngineConfig 两字段、块列表内存底座 + 保留策略、auto cap 计算、
  `pcm_window`/`pcm_epoch` FFI、无设备 error、`tests/test_memory_mode.c`。**✅ 已实现**
  （POSIX ctest 7/7 通过；Windows 留 CI）。
- **S2** Dart：EngineConfigC + FFI 包装、PcmAnalyzer 双后端、pref/设置 UI/警告文案、接线。
  **✅ 已实现**（`engineMemoryPlay` 默认开；策略 auto/自定义/无上限 + 无上限确认框）。
- **S3** 基准与文档：PARITY 分支断言（文件模式 SHA vs 内存模式窗口比对）、
  `architecture.md`/`audio-kernel-zig.md` 定稿同步。**⏳ 待办**
