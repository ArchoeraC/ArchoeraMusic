# 内存播放（不落盘）模式 — 设计规格与验收

> 状态：**规划定稿 · S1（C 引擎）与 S2（Dart 接线/pref/设置）已实现（2026-09-08 落地）；S3 基准与文档收尾待办**
>
> 范围：桌面端 `archoera-audio-engine`（`mediaengine_lib.c` / `audio_engine.h` /
> `archoera_mediaengine.h`）播放层新增「内存播放」能力；Dart 播放层（`engine_bindings.dart` /
> `audio_engine_process.dart` / `playback_notifier.dart`）配套改造（v1 的
> `pcm_analyzer.dart` 已删除）。
>
> 关联：`docs/architecture.md` §5/§9/§10.1、`docs/audio-kernel-zig.md` P5/§15/§16.2。
>
> **v2 频谱（2026-11-04，破坏性更新）**：频谱分析改为引擎侧 50ms 事件推送
> （[`spectrum-analyzer.md`](spectrum-analyzer.md)），内存模式直接读进程内块列表，
> App 播放路径不再经 Dart 拉窗；v1 的公开 FFI 已删除，引擎内部
> 复用 `mem_window`。

## 1. 动机与目标语义

现状（player 模式）无论 `Stable`（FFmpeg）还是 `EraAudio`（Zig 内核），解码 PCM 都
**整曲写盘**：`on_pcm_out`（`mediaengine_lib.c`）把 PCM 同时写 `stream.wav` + `stream.pcm`
（流式喂设备与写盘并行），`stream.wav` 供 miniaudio 文件自播/回退，`stream.pcm` 供引擎频谱线程取窗
（v1 的 Dart `PcmAnalyzer` 拉模式已删除）。

「内存播放」模式的目标：**播放会话的解码产物全部驻留进程内内存，不写任何会话文件**——
流式出声照常；频谱可视化改走内存缓冲（v1 经公开 FFI 拉窗；v2 由引擎
频谱线程直接读块列表并 50ms 事件推送，见 `spectrum-analyzer.md`）。仅当 **raw 设备
流式无法启动**时按用户设定直接报错（见 §5.1），不再回退写盘。

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
                          0  = 自动（按可用内存均衡，含 32 MiB 硬上限，见 §3.3）
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
> - `cap=auto/自定义` ⇒ 先全量存，到 cap 才退化滚动；auto 的 cap 很小（见 §3.3），
>   实际等价于「实时分析窗口 + 有限回访」——频谱取窗只在播放头附近取帧，
>   全量整曲驻留没有消费者，故默认收敛为有界窗口。

> **缓冲复用池（2026-09-30 增补，纯内存治理）**：淘汰 / `mem_reset`（seek 重建、
> 无缝切换）交还的块缓冲不再 `free`，而是进入**同会话缓冲池**，后续 append 优先
> 取「容量够用的最小缓冲」复用（best-fit）。此举消除解码过程中数千个 16 KiB 小块
> 反复 `malloc/free` 造成的堆碎片（实测 glibc 下 RSS 只涨不缩）。池字节数有界
> （固定 **8 MiB**，故「驻留块列表 + 池」总原生内存 ≤ cap + 8 MiB，auto 下 ≤40 MiB）；
> `destroy` 时清空
> 全部缓冲并调用 `malloc_trim(0)`（glibc 限定）把空闲堆归还 OS——否则单会话释放的
> 保留区不会回退，跨曲累积表现为 RSS 持续上涨。

### 3.3 自动 cap 计算与硬性封顶（`pcm_mem_cap_kb=0`）

引擎启动按当前**可用内存**均衡（复用 scraper `detectParallelism` 同款读取：Linux
`/proc/meminfo MemAvailable` / macOS `sysconf(_SC_AVPHYS_PAGES)` / Windows
`GlobalMemoryStatusEx`）：

```
floor = 8 MiB
cap   = clamp(可用内存 × 0.1, floor, 32 MiB)
```

**硬性上限（32 MiB，不只停留在公式层，运行时强制）**：
- **32 MiB 是自动模式不可逾越的封顶**：驻留 PCM 仅服务频谱取帧（v1 公开 FFI /
  v2 引擎频谱线程直接读块列表，实际只需最近 `fftSize≈12288` 样本 ≈ 256ms（48kHz，
  VQT 最长窗），全量整曲
  驻留没有消费者，故 auto 收敛为小窗口——把单会话原生内存从「整曲（数百 MB，高解析
  更大）」压到有界 ≤32 MiB；
- **计算故障回退**：可用内存查询失败或返回异常值 → 直接回落保守下限（8 MiB），
  绝不因“拿不到数值”而放大上限；
- **超量强制**：每 append 一块后校验 `bytes > cap` → 立即自队头逐最旧直至 `≤ cap`
  （防“整批写入/记账偏斜”瞬时越过 cap）；
- **用户优先**：若用户设置了上限（`pcm_mem_cap_kb > 0`），有效 cap = 用户值，引擎**绝不越过**
  用户设定（也不再套用 32 MiB——显式选择且已警告）；`-1` 无上限同理须显式警告。auto 仅在用户
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

### 5.3 取窗接口（v1 公开 FFI 已删除，改内部接口）

> **2026-11-05**：`archoera_mediaengine_pcm_window` / `pcm_epoch` 已从公开
> 头文件与动态库导出中删除；Dart/CLI 不再有取窗入口。引擎自身的频谱线程走
> `src/mediaengine_internal.h`（不导出、不承诺 ABI）：

```c
/* 生产频谱取窗（内存块 / 流式环 / stream.pcm 分派） */
int era_mediaengine_read_window(ArchoeraMediaEngine *e, int end_pos_ms,
                                int frames, float *out_l, float *out_r);
/* 白盒测试用：内存块窗口（blocking lock + 曲尾截断） */
int era_mediaengine_mem_window(ArchoeraMediaEngine *e, int end_pos_ms,
                               int frames, float *out_l, float *out_r);
/* 内存会话重建计数（seek 重建 +1） */
int era_mediaengine_mem_epoch(ArchoeraMediaEngine *e);
```

- `read_window` 与生产频谱线程共用同一实现；尾部未解码返回 -1，服务层据此
  退回因果窗口。
- `mem_window` 保留旧「远超曲尾截到末块」语义，仅 `tests/test_memory_mode.c`
  / `tests/test_pool_pipeline.c` 直接编译 `mediaengine_lib.c` 时使用。
- 两个符号不带 `ARCHOERA_MEDIAENGINE_API`、不进 Windows `.def`，动态库中
  不可见（`nm -D` 已确认）。

## 6. Dart 配套

> **v2 起 App 播放路径不再使用本节的双后端拉模式**：`PlaybackNotifier` 只消费
> `EngineFft` 事件；v1 的 `PcmAnalyzer` / `MemoryPcmAnalyzer` 与对应 FFI 绑定
> 已于 2026-11-05 删除。以下为历史规格（保留作语义参考）。

- `EngineConfigC`（`engine_bindings.dart`）追加 `noDiskCache` / `pcmMemCapKb` 两字段；
  create 传入。
- `PcmAnalyzer` 拆双后端，`frameAt` 接口不变：
  - `FilePcmAnalyzer`（现状，文件模式）；
  - `MemoryPcmAnalyzer`（内存模式）：帧索引本地缓存；每次 frameAt 校验 epoch，命中拉
    取窗，miss 按静默；无需 `scan` 文件增量扫描（历史 v1 规格）。
- `playback_notifier.dart` 按开关选择实例；设置默认内存模式。
- 在线源行为不变（SongCache 开关独立，见 §1 组合表）。

## 7. 文件模式强制入口（基准/测试）

- 设置 `engineMemoryPlay=false`；
- 或 env `ARCHOERA_ENGINE_FILE_MODE=1`（Dart 启动注入 `no_disk_cache=0`）。

文件模式为字节级现状（PARITY SHA 基准在文件模式下执行）；内存模式默认下，基准/回归按
取窗比对（float 误差 ≤1e-4），不再比对文件。

## 8. 验收标准

1. `tests/test_memory_mode.c`：
   - 内存模式（含中途 seek / 暂停续播 / destroy）：会话目录**不产生** `stream.wav/.pcm`；
   - `ARCHOERA_ENGINE_FILE_MODE=1`：写盘与现状逐字节一致；
   - 无设备场景：emit error 且不落盘；
   - 取窗（`era_mediaengine_read_window` / `_mem_window`）：0/-1/-2 语义；`cap=auto` 边界、`cap=-1` 全量可回访、达 cap 滚动淘汰
     行为；seek 重建后 epoch+1 且旧帧不可再取；
   - **cap 强制不越界**：auto 模式注入“内存查询超大/查询失败”用例 → 实际 cap 仍 ≤32 MiB
     （失败回落下限档）；伪造音频超量批次 → append 后记账立即淘汰、不越过 cap；
     `pcm_mem_cap_kb>0` → 实测绝不越过用户值。
2. Dart 单元/集成（历史 v1，已随分析器删除）：内存/文件窗口样本误差 ≤1e-4；设置默认开；
   无上限确认框与文案出现；三档策略映射正确。
3. 回归：文件模式（env 强制）下既有引擎测试与 PARITY 基准全绿。
4. POSIX 编译 + C 测试通过；Windows 留 CI（沿用既有 `#ifdef _WIN32` 与 UTF-8 宽字符边界
   约定）。
5. RSS 有界性：auto 模式长播 RSS 增量有界且**实测不超过 32 MiB**（含查询故障/超量用例）；
   `destroy` 后 `malloc_trim` 使空闲堆归还 OS（glibc）；用户设限时不越过用户值；
   `cap=-1` 用户显式知悉（含警告）。

## 9. 分阶段实施

- **S1** C 引擎：EngineConfig 两字段、块列表内存底座 + 保留策略、auto cap 计算、
  取窗接口、无设备 error、`tests/test_memory_mode.c`。**✅ 已实现**
  （POSIX ctest 7/7 通过；Windows 留 CI）。
- **S2** Dart：EngineConfigC + FFI 包装、PcmAnalyzer 双后端、pref/设置 UI/警告文案、接线。
  **✅ 已实现**（`engineMemoryPlay` 默认开；策略 auto/自定义/无上限 + 无上限确认框）。
- **S3** 基准与文档：PARITY 分支断言（文件模式 SHA vs 内存模式窗口比对）、
  `architecture.md`/`audio-kernel-zig.md` 定稿同步。**⏳ 待办**
