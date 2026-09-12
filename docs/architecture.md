# ArchoeraMusic 架构规划

> 状态：规划稿 v3 · 2026-08-05（2026-09-06 修订）
>
> **去侧车化（2026-09-06）**：早期规划的 **Node 侧车方案已整体砍掉**，
> 仓库不保留任何侧车代码；桌面端为 **Flutter UI + 纯 Dart 业务层（平台 API 纯 Dart 直连）+ 多语言
> 原生工具链 FFI 直连**（C 引擎 / C# 扫描 / C++ 刮削 / Rust 下载 / Go Subsonic 均进程内 FFI，
> 子进程仅余 `archoera-vault` 凭据保险库），**无 Node 进程、无本地监听端口**。
> 本文涉及侧车 / stdio RPC / Web 兼容路径的章节均已压缩为简注（§2/§4/§12.0）。
>
> **代码归属（2026-08-09）**：所引用的服务端代码（Go Subsonic、C 音频引擎、C# 扫描、C++ 刮削、
> Rust 下载引擎等）均由本仓库作者**自行编写**，不在任何上游主仓库内，本项目不包含其代码。
>
> **引擎路线（2026-08-16）**：音频主引擎 = **FFmpeg 默认主引擎 + Zig 内核逐格式渐进替换 + C 壳保留
> （FFI/CLI）**（详见 `docs/audio-kernel-zig.md`）；Dart/FFI 契约不变，行为零回归。
>
> **播放输出（2026-09-08）**：桌面播放新增「**内存播放（不落盘）模式**」（默认开启，独立于
> Stable/EraAudio 引擎选择与 SongCache）；解码 PCM 驻留进程内块列表，频谱经 `pcm_window` FFI
> 拉取，不写 `stream.wav/.pcm`。本文 §5/§9/§10.1 中「PCM 落盘 `stream.wav` + miniaudio 自播」
> 等描述均指**文件模式**（显式开关 / env `ARCHOERA_ENGINE_FILE_MODE=1` 保留）。详见
> `docs/audio-memory-playback.md`。
>
> 定位：独立开发的 Flutter 混合架构音乐播放器（桌面为主），以 AGPL-3.0 开源
>
> **核心原则：Flutter 承载 UI 与业务层，后端与原生工具链整体自行编写（C 音频引擎 / C# 扫描 / C++ 刮削 / Rust 下载 / Go Subsonic）。**
>
> **平台能力外观（2026-09-08）**：播放器依赖的 OS 系统能力（防休眠 / 媒体会话与蓝牙耳机控制 /
> 天气系统定位等）以**能力接口 + 每平台实现**收敛（详见 `docs/platform-capability-facade.md`）；
> 主程序只依赖接口，平台差异藏于各平台 adapter，能力缺失静默降级。

---

## 1. 项目定位

| 项 | 说明 |
|---|---|
| 名称 | ArchoeraMusic |
| 形态 | Flutter 桌面音乐播放器（Windows / macOS / Linux），**桌面为主** |
| 架构 | 混合架构：Flutter UI + **纯 Dart 业务层（平台 API 纯 Dart 直连）** + 多语言原生工具链（**FFI 直连**）；原 Node 侧车方案已废弃（§4 简注） |
| 代码归属 | 全部自行编写（含所引用的服务端代码），不在任何上游主仓库内 |
| 开源 | 以 AGPL-3.0（`AGPL-3.0-or-later`，含后续版本弹性条款）发布（仓库根 LICENSE 已提供） |
| 第三方依赖 | KuGouMusicApi（MIT）、NeteaseCloudMusicApi 相关实现（MIT）、TagLibSharp、FFmpeg 等——保留第三方声明 |

**「让不同架构发挥最大效能」的具体分工：**

| 架构 | 承担 |
|---|---|
| Flutter / Dart | UI、动画、歌词渲染、状态管理、窗口；**媒体渲染驱动**（FFI 直连引擎库，50ms 轮询 pollEvent；实际渲染由引擎内 miniaudio 承担）；平台 API / 数据层 / 配置（纯 Dart） |
| C | **统一音频引擎（主引擎）**：解码 + EQ/响度/限幅/FFT/变速变调 + PCM 输出 + miniaudio 自播（`archoera-audio-engine`；**2026-08-16 路线：FFmpeg 默认主 + Zig 内核渐进替换，见头部更正块**）|
| C# | 音乐库扫描（TagLibSharp，`archoera-scanner`） |
| C++ | 元数据刮削（多源并发，`archoera-scraper`） |
| Rust | 下载引擎（CLI `archoera-downloader`）、`tempo-rs`（变速变调静态库，C 引擎内置）、媒体控制/任务栏歌词（napi，Phase 3）|
| Go | Subsonic 协议层（自用桌面端可选启用） |

> **音频架构要点**：桌面端与 Web 端共用**同一条 C 引擎管线**（`archoera-audio-engine`），
> 全部 DSP（EQ/响度/FFT/变速变调）在 C 引擎内完成；桌面端经 **FFI 直连**
> `libarchoera_mediaengine`（库内线程转码 PCM 落盘 + miniaudio 自播，2026-08-07）。
> Rust `native/audio-engine`（napi 直出）**不在 ArchoeraMusic 引入**，仅留在上游桌面端使用。

**核心处理逻辑技术选型原则**
- **原生优先**：平台协议 / 数据层由纯 Dart 承接；重型处理由原生工具链 FFI 直连（C 音频引擎、C# 扫描、C++ 刮削、Rust 下载）。
- **必要时允许 C/C++**：CPU 密集（加密、格式转换、批量处理）、大缓冲流式转发、常驻大对象缓存等场景，经 **FFI** 调用原生实现。
- **下沉决策流程（证据驱动，避免过度重构）**：`profile（内存基线 / CPU 热点）→ 命中阈值 → 只下沉该模块 → 回归对比`。
- **候选下沉点（按需启用，不主动重写）**：歌词/字幕解析与标准化、CUE 分轨、weapi/eapi 加解密、tag 编辑（C++ TagLib 已有）、loudness 分析（scanner 侧已有）。

---

## 2. 链路落地形态（原「server 方案 → ArchoeraMusic 复用映射」简记）

早期曾规划 Node 侧车后端（Hono + better-sqlite3 + 子进程调度，
SQLite 写入经 `/api/db/*` 代理串行化），2026-09-06 随去侧车化整体废弃，未保留代码。
各链路实际落地形态：

| 链路 | 落地形态 |
|---|---|
| 在线平台 API / 歌词 | **纯 Dart 移植**（`app/lib/core/apis/`：netease / kugou / qqmusic / lyric，纯 Dart 直连） |
| 音乐库 / 扫描 / 刮削 / 下载 | **原生模块 FFI 直连进程内**（C# / C++ / Rust），直写 SQLite（§8） |
| 播放 | **C 引擎 FFI 直连**（PCM 落盘 + miniaudio 自播，§5） |
| 配置 / 会话 / 队列 / 缓存 | **Dart 本地**（`config/settings.json` 原子写 + vault 2-of-2 保险库 + drift/Hive） |
| Subsonic | **Go c-shared FFI 直连**（可选启用；与独立服务端共享同一份代码，build tag 区分） |

---

## 3. 进程模型

（原 Node 侧车进程模型已随去侧车化废弃，仅保留现状。）

```
┌─────────────────────────────────────────────────────────────┐
│ Flutter App（单进程）                                        │
│  · UI 层（Dart）：主窗口 / 歌词窗口（桌面歌词·动态岛·任务栏）  │
│  · 业务层（Dart，Riverpod）：播放控制·歌词同步·队列/历史·主题 │
│  · 桥接层（FFI 直连，库内）：                                │
│    ├─ libarchoera_mediaengine（C 引擎：转码+miniaudio 自播） │
│    ├─ archoera-scanner / scraper / downloader（原生模块）    │
│    ├─ libarchoera_subsonic（Go c-shared，可选启用）          │
│    └─ libfft.so（频谱拉模式分析，§10.1）                     │
└─────────────────────────────────────────────────────────────┘
子进程：仅 archoera-vault（凭据保险库，安全边界，§8）。
原则：桌面端零 TCP 端口、无 Node 运行时（历史侧车方案见 §2/§4 简注）。
```

---

## 4. Node 侧车方案（历史，一笔带过）

曾规划 fork `server/` 为 `sidecar/`（stdio JSON-RPC 控制面复用 Hono 路由 + spawn 原生 CLI +
Web 兼容 OGG 流播放服务），Phase 0/1 短暂实施（spawn + `/api/health` + RPC 桥）后于
2026-09-06 整体砍掉：桥接与 Node 运行时（~30-60MB/平台）复杂度与体积不划算，桌面端改为
**纯 Dart 直连 + 原生 FFI**（§2/§3/§6）。详细设计不再保留，仅存档于 git 历史。

---

## 5. 音频播放链路（决策细化）

> **决策：以 C 引擎 `archoera-audio-engine` 为统一主引擎**。
> EQ/响度/限幅/FFT/变速变调全部在 C 引擎内完成。桌面端 Flutter **FFI 直连**引擎库
> （`libarchoera_mediaengine`，库内线程转码 PCM 落盘 + miniaudio 自播，2026-08-07 起，
> §5.1）。（原 Web 兼容 OGG 流播放路径已随侧车方案移除。）
> Rust `native/audio-engine`（napi 直出）**不引入** ArchoeraMusic（仍留在上游桌面端维护）。
> **引擎路线（2026-08-16 决策）**：主引擎采用 **FFmpeg 默认主 + Zig 内核渐进替换 + C 壳（FFI/CLI
> 保留）**（详见 `docs/audio-kernel-zig.md`）；本节描述为 C 引擎现状，迁移过程中默认仍 FFmpeg
> （零回归），Zig 逐格式验收后接管（Dart/FFI 契约不变）。

> **播放输出（2026-09-08 变更）**：桌面播放**默认内存模式**（不写 `stream.wav/.pcm`，独立开关，
> 与 Stable/EraAudio 及 SongCache 均独立）；本小节及 §9/§10.1 的「PCM 落盘 + miniaudio 自播」
> 描述在实现后仅适用于**文件模式**（设置关 / env `ARCHOERA_ENGINE_FILE_MODE=1`）。规格与验收见
> `docs/audio-memory-playback.md`（S1 引擎 / S2 Dart 已实现，S3 基准收尾待办）。

### 5.1 链路总览（桌面端 FFI 直连引擎，2026-08-07 落地，取代 08-06 spawn+UDS 链路）

```
歌曲源（在线 URL / 本地文件 / 音乐库 trackId）
  → Dart `AudioEngineProcess` FFI 加载 libarchoera_mediaengine（EngineBindings，
     效果配置从播放器状态继承）
  → 库内引擎线程：decode → resample → eq → loudness → limiter → tempo → fft
     （player 模式 skip_encoder=true，不再 Opus 编码）
  → PCM 落盘 stream.wav（会话目录，全速完整转码）
  → miniaudio 自播（src/player.c；加载 WAV 后播放 → EnginePlaying）
  → 事件：事件 FIFO（ready/status/done/playing/position/ended/error）→ Dart 50ms
     定时 pollEvent 轮询 → EngineEvent（position 只留最新；set_event_interval 降频协商）
  → seek：miniaudio 即时 seek（不重启引擎、不重转码）
  → FFT：UI 按播放位置从本地 PCM 索引按需读帧 → libfft.so（FFI）分析 → 128 bins（拉模式，§10.1）
  → 停止：archoera_mediaengine_destroy（join 引擎线程 + 清会话目录）
```

### 5.2 媒体渲染端选择（Flutter 侧）

| 方案 | 说明 | 倾向 |
|---|---|---|
| **miniaudio 自播（src/player.c）** | 引擎库内自播本地完整 WAV（stream.wav）；seek/音量原生支持；无额外进程、无 libmpv 依赖（2026-08-07 落地）| ✅ 首选 |
| media_kit（libmpv） | OGG/Opus/HTTP 流解码成熟；三平台一套 API | 备选 |
| 纯 Dart 解码 | 无系统依赖，但需自建音量/变速/同步，工作量大 | ✗ |

> 自播模式免去 libmpv 三平台 20~50MB 体积。

### 5.3 关键控制流（桌面端直连）

**Seek**：完整转码落盘后由 **miniaudio 即时 seek**——不重启引擎、不重转码、无毛刺（2026-08-07 落地，取代原「libmpv 本地 seek」方案）
**EQ/音量/变速变调实时调整**：命令 FIFO（`archoera_mediaengine_command`，JSON 命令）——Flutter `AudioEngineProcess.sendCommand` 直连调用
**FFT 频谱**：库内 PCM 输出 → 本地落盘索引 → 按播放位置 `frameAt(pos)` 按需读帧 → FFI `libfft.so`（拉模式，§10.1）
**进度/状态**：事件 FIFO `pollEvent`（50ms 轮询，position 事件合并只留最新；`set_event_interval` 降频协商）
**切歌**：`archoera_mediaengine_destroy`（join 引擎线程）+ 新建引擎实例（库内，无进程切换）；预加载下一首为 Phase 3 优化项

### 5.4 音质与带宽策略

**桌面端：PCM 落盘 + miniaudio 自播（player 模式，2026-08-07 起）**

| 场景 | 输出 | 说明 |
|---|---|---|
| 在线音源 | **raw PCM（float）落盘 stream.wav**，miniaudio 自播 | 跳过 Opus 编码（`skip_encoder=true`）；管线 DSP 完整保留，无有损重编码 |
| 本地文件 | 同上（同一条管线）| 与在线共用管线；无损直通播放 |

- **播放无损**：桌面端不重编码，PCM 直出 + miniaudio 播放，无 Opus 二次有损
- **曲库磁盘文件始终无损原样**（转码只作用于播放路径）
- **seek**：完整转码 + miniaudio 即时 seek（§5.3），与在线一致，无毛刺

**FLAC/raw PCM 直通模式（桌面端已默认）**
- player 模式即 raw PCM 直通（`skip_encoder=true`），管线 DSP（EQ/响度/限幅/FFT/tempo）完全复用
- FLAC 直通输出模式仍为可选（无损回放场景）；FFT 与输出格式无关

**FFT 与输出格式无关**
- 管线顺序 `decode → resample → eq → loudness → limiter → tempo → **fft** → encode（可选）`：FFT 分析在编码**之前**
- 数据链路：库内 PCM → PcmAnalyzer 落盘索引 → `frameAt(pos)` → FFI libfft.so（§10.1）——与输出格式无关

**带宽分析（在线场景）**
- 外网带宽只消耗在**源下载**；桌面端转码输出即本地文件（无网络开销）——播放与网络解耦，源下载抖动仅影响转码完成时间
- 量级：Opus 192kbps ≈ 24KB/s（2Mbps 的 ~10%）；即使音源 FLAC ~1Mbps 也仅占 2Mbps 的一半
- 播放与网络解耦：桌面端全速转码落盘后本地播放，源下载抖动仅影响转码完成时间，不影响已就绪播放

### 5.5 播放控制语义（桌面端 FFI 直连）
```
load(track) → Dart FFI 创建引擎实例（EngineBindings.create，player 模式）→ 库内线程完整转码
             → done（stream.wav 就绪）→ miniaudio 加载播放（EnginePlaying）
play / pause / stop / seek(sec)          （seek 走 miniaudio 即时 seek；pause 走 miniaudio）
setVolume / setFadeDuration              （miniaudio 侧音量；引擎 preamp 管余量）
setEqualizerEnabled / setEqualizerBands / setPreampGain   → 命令 FIFO set_eq
setNormalizationEnabled / setFftEnabled / getFftData(128)  → 命令 FIFO set_* + 本地 FFT（§10.1）
setSpeed / setPitch / setPitchSync       → 命令 FIFO set_tempo_*（重启生效）
事件：事件 FIFO pollEvent（50ms 轮询，position 只留最新；set_event_interval 降频协商）
      → stateChanged / ended / sourceError / position / fftData / outputStalled
```
> 高频推送遵循原项目「隐藏即静默」：频谱不可见时不推 FFT；歌词窗口隐藏时不推位置。

### 5.6 C 引擎 spawn 参数与设置映射（可执行清单）

**spawn 参数表**（`archoera-audio-engine` CLI，参数与引擎 `--help` 一致；**桌面端 FFI 直连已改用 `EngineConfig` 结构体传参（`engine_bindings.dart`），本表对应 CLI 模式**）

| 参数 | 默认 | 说明 |
|---|---|---|
| `<source>` | — | 位置参数：在线 URL / 本地文件路径 |
| `-b --bitrate` | 128000 | Opus 比特率（bps），按 QualityLevel 映射 |
| `-f --frame-size` | 20ms | Opus 帧时长 |
| `-r --sample-rate` | 48000 | 输出采样率（Opus 固定 48k） |
| `-c --channels` | 2 | 输出声道数（5.1 源由 swr 自适应下混；设 6 可输出 5.1） |
| `-o --offset` | 0 | 跳过开头 ms（CUE/seek 用） |
| `--eq <10,gains>` | 关 | 10 段 EQ 增益（dB），逗号分隔 |
| `--preamp <dB>` | 0 | 前级增益 |
| `--normalization` | 关 | 响度归一化 |jian ca
| `--normalization-gain <dB>` | 0 | 预计算响度增益（可复用 scanner 分析值） |
| `--no-limiter` / `--limiter-threshold` | -1.0dB | 限幅器开关 / 阈值 |
| `--fft` / `--fft-size` / `--fft-interval-ms` | 1024 / 100ms | 频谱分析（对齐 Web 用 `--fft-interval-ms 50`） |
| `--tempo` / `--tempo-speed` / `--tempo-pitch` / `--tempo-pitch-sync` | [0.5-2.0] / [-12..12] | 变速变调 |
| `--interactive` + `--control-fd 3` + `--fft-fd 4` | 关 | 交互模式：fd3 写控制命令、fd4 读 FFT JSON |
| `--keep-alive-ms <n>` | 0 | 转码完成（EOF）后保持进程存活 n ms 等待迟到消费者（默认 10s），避免短音频 done 前消费者未连上 |
| `--stream-uds <path>` | — | OGG/Opus 流输出到 UDS（替代 stdout）；引擎**等待消费者连上（15s）后才开始转码**，保证 OGG 从头完整 |
| `--pcm-uds <path>` | — | 原始 float PCM 块输出到 UDS：`[pos_ms|samples|channels] + float`（小端，4096 samples/帧），供 FFT 拉模式（§10.1） |
| `--control-uds <path>` | — | 控制事件 JSON 行输出到 UDS（替代 fd3；Dart `Process` 无法传额外 fd）；`control_send_line()` 优先 UDS，否则 fd3 |
| stdout / stderr | — | 无 UDS 时 OGG/Opus 走 stdout；stderr 日志 |

**QualityLevel → bitrate 映射**（对齐原项目 `web/api/player.ts`）

| 等级 | bitrate |
|---|---|
| `hi-res` | 256 kbps |
| `lossless` | 192 kbps |
| `hq` | 128 kbps |
| `sq` | 96 kbps |
| `lq` | 64 kbps |

**设置项 ↔ 引擎参数映射**（Flutter `PlaybackNotifier` 持有播放器状态，引擎 spawn/重启时继承）

| Flutter 设置 | 引擎参数（启动） | 运行时 control |
|---|---|---|
| 音质 songLevel | `--bitrate` | — |
| EQ 10 段 + 前级 | `--eq <gains>` + `--preamp` | `set_eq {gains, preamp}` |
| 音量 volume | — | `set_volume {gain}`（主音量在 miniaudio 侧，preamp 管余量） |
| 响度归一化 | `--normalization` | `set_normalization {enabled}` |
| 限幅器 | `--limiter-threshold`（默认启用） | `set_limiter {enabled}` |
| 频谱显示 | `--fft` | `set_fft {enabled}` |
| 变速/变调 | `--tempo --tempo-speed --tempo-pitch` | `set_tempo_speed` / `set_tempo_pitch` |
| seek | `-o --offset`（CLI 启动偏移） | `seek {position_ms}`（进程内，Phase 3+；桌面端由 miniaudio 即时 seek，§5.3） |

---

## 6. 原生工具链（复用清单；2026-09-06 现状：全部 FFI 直连进程内，无侧车 spawn）

| 二进制 | 语言 | 调用方 | 协议 |
|---|---|---|---|
| `archoera-scanner` | C#（TagLibSharp）| **Dart FFI 直连（进程内）** | FFI 结果/进度直返；SQLite 直写（§8） |
| `archoera-scraper` | C++（libcurl + TagLib）| **Dart FFI 直连（进程内）** | FFI 进度回调 + 结果直返 |
| `archoera-downloader` | Rust（reqwest）| **Dart FFI 直连（进程内）** | FFI 进度事件 + 结果直返 |
| `archoera-audio-engine` | C（FFmpeg + miniaudio）| **主引擎**（Dart FFI 库内加载，2026-08-07）| FFI：`archoera_mediaengine_*`（库内线程转码 PCM 落盘 + miniaudio 自播 + pollEvent FIFO）；CLI 模式保留 stdout OGG + fd3/fd4 |
| `tempo-rs` | Rust（signalsmith-stretch）| 静态链接进 C 引擎 | C FFI（`HAS_TEMPO` 条件编译）|
| Go `subsonic` | Go | **Dart FFI 直连（Go c-shared，可选启用）** | 库内提供服务；与独立服务端共享同一份代码（build tag 区分） |

**SQLite 写入规范（2026-09-06 修订）**：现行模型见 §8——
WAL + busy_timeout 并发访问（scanner 直写媒体库、subsonic FFI 直读直写、Dart 本地层直写用户数据），以 WAL 读写隔离避免 `SQLITE_BUSY`。

---

## 7. 平台 API 接入

### 7.1 Netease（首期，已全量 Dart 移植，`app/lib/core/apis/netease/`）
- `core/`：weapi/eapi/linuxapi 加解密、request（国内 IP 池）、xeapi、device、cookie、option、ncbl、config、cache
- `modules/`：**全量 ~80 个**——登录（cellphone/QR/token/refresh/logout/status）、歌单（detail/tracks/create/delete/subscribe/update）、云盘（upload/check/nos/pub/import/lyric）、评论（hot/music）、FM、搜索（suggest/hot/multimatch/match）、歌词（lyric/lyric_new）、专辑/歌手、榜单、每日推荐、用户（account/detail/level/record/playlist/follows）等
- 会话：`callNetease(name, params)` 等价能力 + 会话缓存 + 登录态本地持久化（vault，见 §7.4/§8）
- 登录：二维码（login_qr_create/key/check）→ Flutter 展示二维码 + 轮询

### 7.2 KuGou（首期）
1. **更新克隆**：`KuGouMusicApi/` = MakcRe/KuGouMusicApi **v1.5.1（2026-02-05）手动拷贝**（非 git 仓库）；上游 main 分支持续更新（2026-08-05 仍有提交），确认落后。本机可直连 GitHub。
   - 操作：`git clone https://github.com/MakcRe/KuGouMusicApi.git` 到工作区替换旧目录，保留旧目录做 diff 参考
2. **提取核心**：`util/crypto.js`（token/签名）、`util/request.js`、`util/runtime.js`、各 `module/*.js`（160+ 端点）逻辑
3. **移植进模块架构**：以纯 Dart 移植为落地形态（`app/lib/core/apis/kugou/`，search/lyric 等已可用），按需从 KuGouMusicApi 补：
   - `song_url`（音源 URL）、`rank_list`/`rank_info`（榜单）、`playlist_detail`/`sheet_*`（歌单）、`search_suggest`、`comment_*`、`login*` 等
   - 注意 `platform` 完整版 vs `lite` 概念版 token 不通用，自用选定一版并在 modules 内封装隔离
4. KRC 歌词解析：已有 `core/krc.ts`（KRC → 标准时间轴），直接复用

### 7.3 QQ Music（后期）
- 纯 Dart 移植（`app/lib/core/apis/qqmusic/`，已落地）：TripleDES + RC4 + qrc 加密、match/search/lyric/leaderboard/hot_search/song_info/song_list

### 7.4 登录与会话管理
- **会话持久化**：各平台登录成功后 cookie 由 Dart 本地层 + vault 持久化，重启不丢
- **二维码登录流程**（netease）：`login_qr_create` → `login_qr_key` → `login_qr_check` 轮询（Flutter 展示二维码 + 定时探测）→ 成功后 `login_status` 确认 + 会话回写
- **登录态检测**：启动/打开播放前调 `login_status`（netease）；失效 → 播放返回 403/401 → `player:sourceError` → UI 提示重新登录
- **登出**：`logout` 清平台 cookie + `sessions` 表
- **多账号**：自用单账号起步，`sessions` 表结构预留多平台多账号切换
- KuGou / QQ 登录（Phase 2/3）：对齐 netease 模式，各自 modules 内封装

---

## 8. 数据存储

数据按访问方与敏感度拆分为双 SQLite 库（均 WAL + busy_timeout，多进程并发读写互不阻塞）：

| 数据 | 存储 | 归属 / 访问方 |
|---|---|---|
| 曲库 tracks（元数据 / 路径 / 时长 / 歌词 / 封面）| SQLite `database/library.db`（WAL）| C# scanner 直写；Go subsonic FFI 直读；Dart（TracksDb）只读 |
| Subsonic 用户 / 收藏 / 播放列表 / 分享 | SQLite `database/user.db`（WAL，独立加密库）| Go subsonic FFI 与 Dart（SubsonicAdmin）直读直写；敏感字段（密码）以 `enc:v1:` AES-256-GCM 字段级加密落盘 |
| 平台会话 cookie / 下载任务 | Dart 本地层（drift/Hive + vault） | 登录态与下载任务本地持久化（原侧车 `sessions`/`downloads` 表方案已废弃） |
| 配置 | `config/settings.json`（原子写 + 迁移）| Dart |
| 队列 / 播放历史 / UI 偏好 | Dart 本地（drift 或 Hive）| Flutter |
| 日志 | `logs/` | 各进程各自 |

**拆分原则**：媒体库（高频读写、多进程共享、无敏感数据）与用户数据（低频、含凭据、需加密）物理隔离——
- 用户库路径 `dataDir/database/user.db`，与媒体库同目录独立文件，密钥自举到 `dataDir/secret.key`；
- 旧版（library.db 内嵌 subsonic_* 表）数据在服务端启动时经 `MigrateUserDB` 自动迁移到 user.db 并删除媒体库旧表（幂等，密文原样搬运不重加密）；
- scanner 直写媒体库、subsonic 服务端直读直写媒体库与用户库、前端读媒体库的四方访问模型保持不变。

---

## 9. 通信协议（桌面端零 TCP 端口）

**原则**：桌面端**不暴露任何 TCP 端口**——引擎控制走 Dart↔引擎 FFI 符号面（命令/事件 FIFO，库内），媒体面为库内线程直接转码落盘（`stream.wav`）+ miniaudio 自播；业务 API 为纯 Dart 直连（原侧车 stdio RPC / WS / Web 兼容路径已随侧车移除）。

| 通道 | 内容 | 端口占用 |
|---|---|---|
| **业务 API** | 平台 API / 歌词 / 曲库 / 配置——纯 Dart 直连实现（§2） | **无** |
| **引擎控制：FFI 命令/事件 FIFO** | Flutter ↔ 引擎库内：`archoera_mediaengine_command`（JSON 命令）+ `archoera_mediaengine_poll_event`（50ms 轮询事件 FIFO）——Dart FFI 直连（§5.1） | **无（库内）** |
| **引擎媒体：库内 PCM 落盘** | 库内线程转码 PCM → 会话目录 `stream.wav`（完整文件）→ miniaudio 自播 / FFT 按需读帧（§10.1） | **无（库内）** |
| 子进程 stdio | `archoera-vault` 凭据保险库（serve/init，安全边界） | 无 |

**安全**：桌面端零 TCP 端口；会话目录置于临时私有目录（0700），库内 FIFO/文件不可从外部访问。

**为何不需要媒体口**：桌面端转码与播放都在库内（PCM 落盘 `stream.wav` + miniaudio 自播），无进程间媒体通道、无 EOF 问题，loopback 端口与 UDS 均不再需要。

---

## 10. Flutter 层设计

- **窗口**：Phase 1 单主窗口；歌词窗口（桌面歌词/动态岛）Phase 3 用 `desktop_multi_window` / 平台壳多窗口
- **状态管理**：Riverpod；**路由**：go_router
- **i18n（Flutter 原生，非自研）**：`flutter_localizations` + `intl`/`gen_l10n`（ARB 管道）——复用原项目 8 语言文案，首期 zh-CN / en-US，其余后续补
- **事件总线（Dart 侧统一事件通道）**：`EventBus`（StreamController 多路复用）承载两类事件——引擎事件（FFI `pollEvent` 转译，`player:*`/扫描/下载进度）与本地事件（播放队列、UI 状态）；UI 层只依赖总线，不直连传输层
- **主题**：亮/暗 + 封面动态取色
- **核心页面**：搜索、歌单/榜单、播放页（滚动歌词 + 频谱）、队列、设置、登录（二维码）、音乐库（Phase 3）、下载（Phase 3）
- **歌词渲染**：自绘文本行，沿用原项目时间轴插值/锚点算法；格式解析（LRC/YRC/KRC/QRC/TTML）在 Dart 侧完成
- **播放控制**：`PlaybackController`（Dart）封装 §5.2 语义，播放走直连引擎（§5.1），业务 API 为纯 Dart 直连
- **桌面集成（Phase 3+）**：媒体键、系统托盘、全局快捷键、任务栏缩略图——通过原生 media-ctrl（napi，规划中）/ 平台壳插件

### 10.1 音频频谱（FFT 可视化）

**数据链路（桌面端：库内 PCM 落盘 → 本地索引 → 拉模式，2026-08-07 更新）**

```
C 引擎 fft 阶段（管线内 DSP 之后、编码之前，与输出格式无关，见 §5.4）
  └─ 库内 PCM 输出 → 会话目录落盘（stream.pcm / stream.wav 同源）
        → PcmAnalyzer 建 (posMs → fileOffset) 内存索引
        → UI 按 miniaudio 实际播放位置（EnginePosition 事件）frameAt(posMs) 二分定位 → 按需读文件
        → FFI libfft.so（fft_process_multi / fft_get_spectrum_norm_stereo）→ 128 bins
        → 频谱组件（CustomPainter，RepaintBoundary 局部重绘）
```
- **拉模式原因**：引擎全速转码可快于实时，UI 必须以播放位置取帧而非顺序消费；任意位置（含回退 seek）可回溯
- 引擎转码期间即可用（缓冲已落盘的块）；帧间插值沿用原 BottomSpectrum.vue 算法（见下）

**FFI 细节（fft_bindings.dart）**
- 加载 `build/libfft.so`（EnginePaths 同规则解析）；`fft_create(sampleRate, fftSize)` + **`fft_set_enabled(1)` 必须显式调用**（默认 disabled，否则输出全 0）
- `fft_process_multi(interleaved, samples, channels)` → `fft_get_spectrum_norm_stereo` 128 bins（dB 归一化 [0,1]）
- **输入缓冲 fftSize×32 float 防越界**（引擎块 4096×2ch=8192 float > 旧 6144 缓冲，曾致段错误）；samples 截断到 fftSize 与 C 侧一致

**C 引擎 FFT 能力（复用）**
- 立体声独立分析（ldata/rdata）；Hann 窗 + 指数平滑（EMA）+ 峰值保持衰减 + 对数 dB（-60dB 截断）
- **自适应多声道（1~6ch，含 5.1）**：`fft_process_multi` 按声道数自动下混为 L/R，ITU-R BS.775 系数——
  `5.1（FL FR C LFE BL BR）→ L = FL + 0.707·C + 0.707·BL，R = FR + 0.707·C + 0.707·BR，LFE 不入下混`
- 频段任意聚合（对齐 Web 用 128 bins，`--fft-size 1024`）；`--fft-interval-ms`（Web 用 50ms ≈ 20Hz；桌面端拉模式不受其约束）

**Flutter 渲染（复刻原项目 `BottomSpectrum.vue` 算法）**
- 帧间时间插值：`t = min((now - lastUpdate)/PUSH_INTERVAL, 1)`；上行 attack `0.4` / 下行 decay `0.88`——上行灵敏、下行柔和，消除 20Hz 阶梯感
- `SKIP_LOW` 跳过低频 bin（去 DC 噪声）
- mirror / split 双声道显示模式（L 镜像左、R 右——数据天然立体声，非同相重复）
- bar 空间平滑：每 bar 聚合区间 `[start-1, end+1]` bin 均值；bar 宽度 `spectrumBarWidth`（默认 4px）
- 配置映射：`enableSpectrum` / `spectrumBarWidth` / `spectrumDisplayMode(mirror|split)`——存 Dart 本地 `config/settings.json`（§10.6）

**节能（隐藏即静默）**
- 频谱可见才开启 `_pollSpectrum` Ticker，不可见停止轮询；本地文件拉帧无订阅/推流开销，「隐藏即静默」= 停止 UI 轮询

**实现（2026-08-06 已落地）**
- `pcm_analyzer.dart`：PCM 落盘 + 二分索引；`frameAt(posMs)` 按需读文件做 FFT（长音频零内存全量缓冲）；`isDone/bytesIn/frameCount` 诊断字段
- `fft_bindings.dart`：`FftAnalyzer` FFI 封装（`fft_set_enabled(1)` 显式；缓冲 fftSize×32 修复段错误）
- `playback_notifier.dart`：`_pollSpectrum()` 按 `state.position` 每 50ms 拉帧；`PlaybackState.fft`（`FftFrame{ldata,rdata}`，copyWith 哨兵支持置空）；`stop()` 清空 `state.fft`
- `widgets/spectrum_view.dart`：CustomPainter + Ticker（~16ms 重绘）复刻 `BottomSpectrum.vue`——帧间插值、ATTACK 0.4/DECAY 0.88、SKIP_LOW=8、双声道镜像拼接（左倒序 + 右正序，usableLen 240）、bar 空间平滑（±1 邻居）、barWidth 4/gap 3/radius 2、底部对齐
- 消费端：播放页大频谱 + 播放条迷你频谱；`stop()` 清空 `state.fft`（频谱归零）
- 已验证：AUTOPLAY 全链路 `FFT 频谱已启动: 本地 N 帧 @50ms 拉模式`；440Hz 校准 `bin67 val=0.793`

### 10.2 歌词流水线（获取 → 匹配 → 标准化 → 渲染）

**获取（纯 Dart 直连）**
- `app/lib/core/apis/` 全量移植：netease（73 模块 + xeapi/ncbl）、qqmusic（含 QRC 3DES 解密）、kugou（含 KRC 解密）、`lyric/` 匹配层（fingerprint/pickBestCandidate/ttml）
- **多源回退由前端编排**（对齐原项目 `services/lyric/resolve.ts`）：按设置 `lyricSourceOrder`（源顺序，可配置）+ `lyricFormatOrder`（格式优先级）+ `smartPreferOnline` 逐源尝试；命中 `lyricMatchCache`（track 指纹）
- **缓存**：`lyricMatchCache`（歌曲指纹 → 命中源）、`lyricCache`（原始歌词）、`lyricTtmlCache`（TTML overlay）

**标准化（Dart 侧）**
- 解析/标准化全在 Dart（对齐原项目 `parse*.ts`/`resolve.ts` 语义），输出统一行数组 `{ time, text, translation, emphasis, interlude }`；**Flutter 零解析负担**，只消费标准化行数组

**渲染（Flutter）**
- **歌词引擎 Dart 移植（重点工程）**：原项目 `Lyrics/engine/`（AMLL：line-builder / word-builder / spring / line-animations / emphasize / interlude / scroll-preroll / split-words）→ Apple Music 风格逐字/逐词高亮动画、弹簧曲线、间奏处理（详见 §10.7）
- 翻译行：双行模式（原文 + 译文），可开关
- 无歌词回退：显示"纯音乐 / 无歌词"状态
- **歌词窗口（Phase 3）**：独立窗口经引擎 position 事件（50ms `pollEvent`）同步（「隐藏即静默」——窗口不可见不推送）

### 10.3 播放队列与播放模式

- **归属**：队列 / 播放历史 / UI 偏好 / 业务数据（曲库/统计）统一存 **Dart 本地**（drift 或 Hive，§8）
- **模型**：`nextQueue` + `prevHistory` + 当前索引；`PlaybackController` 管理
- **播放模式**：顺序 / 列表循环 / 单曲循环 / 随机（复用原项目语义，随机种子可复现）
- **切歌流程**：next/prev → `load(track)` → Flutter 重建引擎实例（`archoera_mediaengine_destroy` 旧 + create 新，继承播放器状态，库内无进程切换）→ 完整转码 → miniaudio 播放新 `stream.wav`
- **播放统计**：每曲播放完成写 Dart 本地统计；Last.fm scrobble 可选（Phase 3，复用 `apis/lastfm` 思路）

### 10.4 播放容错与降级

| 场景 | 检测 | 处置 |
|---|---|---|
| 源失效（404/403/超时）| 引擎错误 → 事件 FIFO `EngineError` | 可选**自动换源**：以该曲目在另一平台的搜索匹配结果重取 URL 重载（自用增强，可关） |
| VIP/受限音质 | 音源返回受限码/低 bitrate | 正常播放 + UI 显示"受限音质（如 128k）"来源标记，不自动跳转 |
| 网络抖动/断流 | miniaudio `outputStalled` + 引擎暂停输出 | 带宽降级（§5.4）；重试失败 → 暂停 + 提示 |
| 登录态过期 | 播放 403/401 | 提示重新登录（二维码），恢复后继续 |
| 歌词源缺失 | 歌词多源全 miss | 显示"无歌词"，不影响播放 |

- 统一驱动：所有异常走 Dart 事件总线 `player:*`（引擎/服务事件转译），Flutter 单一状态机消费

### 10.5 桥接层细节（Dart）

- **audio_engine_process**（引擎 FFI 直连，2026-08-07）：Dart 加载 `libarchoera_mediaengine`（`EngineBindings.create`，player 模式）→ 库内线程转码；事件经线程安全 FIFO，Dart 50ms 定时 `pollEvent` 轮询 → `EngineEvent`（ready/status/done/playing/position/ended/error）；`done` Completer（转码完成 = stream.wav 就绪）；`stop()` = 后台 isolate 内 `archoera_mediaengine_destroy`（join 引擎线程）+ 删会话目录
- **PCM 落盘**（媒体面）：player 模式 `skip_encoder=true`，管线 PCM 直写会话目录 `stream.wav`（完整文件，无 OGG/Opus 编码；`wavFilePath` = 会话目录）
- **miniaudio 自播**（player.c，库内）：`EnginePlaying`（WAV 加载开始播放）/ `EnginePosition`（50ms position 事件）/ `EnginePlayerEnded`（EOF）；状态机 `idle → loading → playing → paused → ended/error`；`seek()` 即时 seek
- **进程生命周期**：引擎线程在库内（无子进程）；App 退出 → `archoera_mediaengine_destroy`（join）；崩溃检测 → 提示 + 自动重启

### 10.6 桌面配置清单（Dart 本地 `config/settings.json`）

| 分组 | 配置项（示例） |
|---|---|
| 播放器 | 音量、淡入淡出、音质 songLevel（QualityLevel）、EQ 10 段 + preamp、响度归一化、限幅器、变速/变调默认 |
| 歌词 | 字号、对齐、翻译开关、滚动锚点 |
| 频谱 | enableSpectrum、spectrumBarWidth、spectrumDisplayMode(mirror/split) |
| 界面 | 主题（亮/暗/跟随系统）、封面动态取色、语言 |
| 窗口 | 窗口大小/位置记忆、最小化到托盘、启动恢复播放 |
| 下载 | 默认目录、并发数 |
| 平台 | 各平台登录态、首选音质 |

- Flutter 经 Dart 配置层直读写；schema 变更走本地迁移

### 10.7 UI 适配（Web/Vue → Flutter）

**总体策略**：信息架构与交互模型保留，全部组件用 Flutter 原生重写（不复用 Web 组件与 CSS）；首期按自用子集裁剪，后期按需补齐。

**页面映射（首期子集）**

| Web 页面（pages/）| Flutter feature | 首期 |
|---|---|---|
| Home（首页/每日推荐）| `features/home` | ✔（可简化） |
| Search + NavSearch | `features/search` | ✔ |
| Collection/歌单、Liked、Favorites | `features/playlist` | ✔ |
| FullPlayer + PlayerBar | `features/player` | ✔ |
| QueuePopover / QueuePanel | `features/player/queue` | ✔ |
| History / Daily / Cloud / Download / Library / Folders / Artist | 对应 feature | Phase 3 |
| Onboarding（6 步引导）| 并入设置页，不做引导 | ✗ |
| Streaming（Emby/Jellyfin/Subsonic）| Dart 侧 streaming 客户端直连 | Phase 3+ 可选 |
| Admin / 插件市场 / AMLL DB | 自用不需要 | ✗ |

**布局模型**
- `MainLayout`（SideBar + NavHeader + 内容区）→ Flutter `Scaffold` + 自定义导航（侧栏/抽屉可切换）
- 底部 `PlayerBar` 常驻 → 全局持久底部栏，跨路由保持
- `FullPlayer` 全屏覆盖 → Navigator 全屏路由（保留转场动画）
- 标题栏窗口控件（`WindowControls.vue`）→ `window_manager`（最小化/最大化/关闭）

**布局骨架落地（2026-08-06，已实现）**
- 壳：`ui/app_shell.dart` = Row[`SideBar` ｜ Column[NavHeader, 页面区]] + 底部 `PlayerBar`
- `SideBar`（对齐 SideBar.vue）：240↔64 可折叠（AnimatedContainer），Logo + 分组导航（发现：首页/搜索 · 音乐：音乐库 · 个人：我喜欢/收藏/历史 · 其他：下载），对应 7 个 StatefulShellBranch
- `NavHeader`（对齐 NavHeader.vue）：返回 + 全局搜索框（回车跳 `/search?q=`）+ 用户占位 + 主题循环（light→dark→system，`themeModeProvider`）；Linux 窗口控制由系统提供不绘制
- `PlayerBar`（对齐 PlayerBar.vue）：顶部压缩进度条（拖动 seek）+ 左（封面/曲名/会话，点击 `push('/player')`）+ 播放控制 + 右（时间 + 迷你频谱）
- `FullPlayer`：`/player` 顶层 GoRoute（parentNavigatorKey 根，盖住整个壳含播放条）= 渐变背景 + 封面大图 + 频谱 + 进度 + 控制；歌词区（§10.2）待接入

**组件重写清单（S* 组件库 → Flutter）**
- 交互类：SButton/SInput/SSelect/SCombobox/SRadio/SRadioGroup/SCheckbox/SSwitch/SSlider/SNumberInput → Material / 自绘
- 浮层类：SDialog/SDrawer/SPopover/SPopselect/SDropdownMenu/SContextMenu → showDialog + 自绘桌面右键菜单
- 数据类：STabs/SMenu/STree/SVirtualList/SMarquee/STag/STooltip/SImg/SLoading/SColor → 对应 widget / 自绘虚拟列表
- 反馈类：SToast → SnackBar / 自绘 Toast 队列

**歌词引擎（最重移植）**
- `Lyrics/engine/`（AMLL：line/word-builder、spring、line-animations、emphasize、interlude、scroll-preroll、split-words）→ **Dart 全量移植**（§10.2），逐字/逐词高亮、弹簧动画
- 渲染约束：`RepaintBoundary` 局部重绘，文本行用 `TextPainter`，避免整页重建

**动画与主题**
- CSS transitions / ripple 指令 / BackgroundRipple / 封面旋转 → `AnimationController` / 隐式动画
- 主题：theme store + 动态取色（`utils/color.ts`）→ `ThemeData` + `ColorScheme.fromSeed`，亮/暗/跟随系统
- 背景：AppBackground / PlayerBackground / BackgroundRender → 自绘渐变 + 封面模糊

**弹窗与工具**
- useDialog / SDialogProvider → 统一 `DialogService`
- useToast / useCopyText → ToastService / Clipboard
- useDragSort / useMultiSelect / useTrackMenu（右键菜单）→ 自绘实现
- useFmMode / useHeartMode / useImmersiveMode / useFloatingPlayerBar → Dart 状态封装

**i18n**：8 语言 JSON → ARB；首期 zh-CN / en-US，其余后续补

---

## 11. ArchoeraMusic 目录结构

```
ArchoeraMusic/
├── app/                        # Flutter 应用
│   ├── lib/
│   │   ├── main.dart
│   │   ├── core/
│   │   │   ├── services/playback/ # 播放层（2026-08-07 FFI 直连）：audio_engine_process / engine_bindings
│   │   │   │                   #   / pcm_analyzer / fft_bindings / fft_frame / playback_notifier / playback_state / playback_session
│   │   │   └── state/          # providers（DI）
│   │   ├── services/           # PlaybackController / LyricSync / ApiService / Session / Storage
│   │   ├── features/           # search / playlist / player / settings / login / library / lyric-window
│   │   └── ui/                 # 页面、组件、主题、i18n
│   ├── linux/ windows/ macos/  # 平台壳（FFI 库定位 + 资源路径）
│   └── pubspec.yaml
├── audio-engine/               # C 音频引擎（纯原生库：src/ include/ CMakeLists.txt；build/ 产物 archoera-audio-engine、libfft.so）
├── native/                     # Rust：media-ctrl / taskbar-lyric（napi，Phase 3+）；tempo-rs 随 C 引擎仓库
├── tools/                      # 原生二进制三平台构建脚本、同步脚本
├── KuGouMusicApi/              # 上游克隆（更新为最新 main，保留第三方声明）
├── THIRD-PARTY-NOTICES.md      # 三方依赖声明（MIT/AGPL 合规）
└── docs/
```

---

## 12. 实施路线（细化）

| 阶段 | 内容 | 出口标准 |
|---|---|---|
| **Phase 0** 骨架 ✅ | Flutter 三端骨架 + C 引擎构建打通（2026-08-05；原「spawn 侧车 + HTTP/WS 打通」路径已废弃，见 §12.0） | App 可启动、引擎可用 |
| **Phase 1** Netease + 播放 ✅ | **桌面 FFI 直连引擎播放**（完整转码 PCM 落盘 + miniaudio 自播 + seek 即时 + FFT 拉模式，2026-08-07）；平台 API 纯 Dart 直连；Flutter 搜索页、播放页（歌词 + 频谱）、二维码登录、队列 | 可登录、搜索、播放，歌词/频谱同步，任意 seek |
| **Phase 2** KuGou | 移植 kugou 模块（song_url/榜单/歌单）为纯 Dart（`app/lib/core/apis/kugou/`）；Flutter 接入酷狗搜索播放 | 可搜索播放酷狗歌曲 |
| **Phase 3** 补全 | QQ 音乐接入；本地曲库（C# scanner + 音乐库页 + watcher）；本地播放走统一管线（PCM 落盘 + miniaudio 自播，§5.4）；下载（Rust CLI）；桌面歌词窗口；媒体键/托盘（media-ctrl napi）；C 引擎进程内 seek（可选）| 核心功能达成规划子集 |
| **Phase 4** 优化 | C 引擎增强：进程内 seek、预加载/无缝切换；性能/内存基线（沿用原项目 memory discipline）；缓存与并发策略 | 播放体验优化，桌面集成完备 |

### 12.0 历史落地记录（简记）

- **Phase 0（2026-08-05）**：Flutter 三端骨架 + C 引擎构建打通；曾以「spawn 侧车 + `/api/health`」验证链路（已随去侧车化废弃）。
- **Phase 1 桥接改造（2026-08-05）**：曾实现 stdio JSON-RPC 适配器（复用 Hono `app.request()`）与 Dart RPC 客户端——已随侧车整体移除，仅存档于 git 历史。
- **Phase 1 侧车播放服务 + media_kit（2026-08-05）**：曾以「侧车 spawn 引擎 → chunked OGG 流 → libmpv/media_kit 播放」为桌面播放链路；沉淀经验：libmpv 需 `setlocale(LC_NUMERIC,"C")` 否则段错误；流式转码导致「实时增长时长」与完整 seek 语义冲突——该链路已废弃。
- **桌面直连 C 引擎（2026-08-06 起，现行）**：先经「spawn + 三路 UDS + libmpv 播本地文件」过渡（08-06，AUTOPLAY 验证：完整时长恒定 344426ms、连续 seek 即时无重转码、FFT 拉模式），2026-08-07 迁移为 **FFI 直连库内播放**（§5.1/§10.5）。

### 12.1 构建、打包与分发（自用）

| 环节 | 做法 |
|---|---|
| 原生二进制 | 各模块 CMake / cargo / dotnet / go 构建（README「构建与运行」与 CI workflows；Windows 一站式 `app/core/build_windows.bat`） |
| Flutter 构建 | `flutter build linux/windows/macos`；平台壳负责 FFI 库定位与资源路径 |
| 产物结构 | `ArchoeraMusic + resources/{bin/*, lib/*}`（原生依赖按平台裁剪；无 Node 运行时） |
| 分发 | Linux AppImage/tar；Windows zip（无签名 → SmartScreen 提示，自用接受）；macOS 未签名（Gatekeeper 右键打开；必要时 ad-hoc 签名） |

### 12.2 测试策略

| 层 | 方式 |
|---|---|
| 引擎 | `app/core/audio-engine/tests/`（test_fft 等）三平台构建冒烟 |
| Dart | 单元：api 客户端 / 队列模型 / 状态机；Widget：页面与歌词/频谱组件 |
| 集成冒烟 | App 启动 → 平台 API 直连（搜索/歌词）→ **桌面端 FFI 直连引擎**（AUTOPLAY：库内转码 PCM 落盘 → miniaudio 播放 → FFT 拉模式 → pollEvent 事件） |
| 手动回归 | 播放/seek/切歌/登录/下载核心路径清单（自用场景） |

---

## 13. 风险与决策点

| 风险/决策 | 说明 | 对策 |
|---|---|---|
| **Opus 重编码音质** | 桌面端已不再重编码（PCM 直出 + miniaudio，2026-08-07） | 库文件保持无损；FLAC 直通模式（可选）支持 bit-perfect |
| **Seek 体验** | ~~重启引擎 seek 毛刺~~（已改 miniaudio 即时 seek，无毛刺，2026-08-07） | 进程内 seek 为 Phase 3+ 可选优化 |
| C 引擎依赖 | 三平台需 FFmpeg 库（Windows 打包复杂，vcpkg 已打通 2026-08-11）；**Zig 路线：FFmpeg 保持默认主引擎**（`-Duse-ffmpeg` 默认开），逐格式验收后 Zig 接管（详见 audio-kernel-zig.md）| Docker 构建链已有；Windows 用 vcpkg；`-Duse-ffmpeg=false` 纯 Zig 构建为可选裁剪 |
| Flutter 多窗口成熟度 | 桌面歌词窗依赖第三方方案 | Phase 1 单窗口；预留多窗口抽象 |
| KuGou token/平台差异 | 完整版 vs lite 版不通用 | 选定一版，modules 内封装隔离 |
| 自动换源 | 跨平台搜索匹配可能命中不同版本 | 自用增强可关；优先展示当前平台结果 |
| 登录态失效 | 播放中断，需重登 | 凭据持久化（vault）+ 事件总线 `player:sourceError` 提示重登 |
| 受限音质 | 会员/版权受限时仅 128k | 正常播放 + 来源标记显示，不自动跳转 |
| **Web UI 重写** | 38 个 S* 组件 + AMLL 歌词引擎 + 14 类设置页需 Dart 重写 | 信息架构复用 + 首期裁剪（§10.7）；歌词解析在 Dart 侧，歌词引擎为重点工程 |
| 开源合规 | AGPL-3.0 + 三方依赖 | 各模块 `THIRD-PARTY-LICENSES.md` 维护；开源时声明来源 |

---

## 附：已确认决策记录

1. API 层承载：**纯 Dart 直连**（原 Node 侧车方案已于 2026-09-06 砍掉，未保留代码）
2. **音频主引擎：C `archoera-audio-engine`（统一转码管线）**——桌面端 FFI 直连（PCM 落盘 + miniaudio 自播，2026-08-07）；Rust `native/audio-engine` 不引入。**（2026-08-16 修订：FFmpeg 默认主引擎 + Zig 内核渐进替换 + C 壳保留，见 audio-kernel-zig.md）**
3. KuGou 集成：**更新克隆 → 提取核心 → 纯 Dart 移植**
4. 目标平台：**桌面为主**（Windows / macOS / Linux）
5. 首期范围：**Netease + KuGou 在线音乐**
6. 媒体渲染端：~~media_kit（libmpv）~~ → **miniaudio 自播（src/player.c，2026-08-07）**
7. SQLite 写入：**WAL + busy_timeout 并发模型**（§8；原「一律经 `/api/db/*` 代理」方案随侧车废弃）
8. C 引擎待补能力：进程内 seek（Phase 3+ 优化）；桌面端 player 模式默认 raw PCM 直通（`skip_encoder=true`，miniaudio 自播），**FLAC 直通输出模式**（可选；FFT 不受输出格式影响）
9. 带宽策略：桌面端转码输出即本地文件（零网络开销），播放与网络解耦；源下载速率不足仅影响转码完成时间
10. 队列 / 播放历史 / UI 偏好 / 业务数据（曲库/统计/会话）单一事实源：**Dart 本地**（drift/Hive + vault）
11. 歌词流水线：多源回退 + 匹配缓存（lyricMatchCache）+ TTML 标准化（含翻译，lyricTtmlCache），全在 Dart 侧
12. 播放容错：源失效 → 可选自动换源（跨平台搜索匹配，自用增强可关）；受限音质正常播 + 来源标记
13. 桌面配置：Dart 本地 `config/settings.json`（原子写 + 本地迁移）
14. UI 策略：信息架构/交互保留，组件 Flutter 原生重写；**AMLL 歌词引擎 Dart 移植**；歌词解析在 Dart 侧
15. 歌词多源回退由**前端编排**（设置 `lyricSourceOrder`/`lyricFormatOrder`/`smartPreferOnline`），各源直连
16. **核心处理逻辑必要时可用 C/C++**：性能瓶颈/算法密集时下沉原生（FFI）；下沉需 **profile 证据驱动**，不主动重写
17. **桌面端零 TCP 端口（§9）**：控制面为纯 Dart 直连；媒体面由**库内线程直接转码落盘（PCM → `stream.wav`）+ miniaudio 自播**承载（无 loopback 媒体口、无 UDS）
18. Flutter 原生能力直接用：i18n 走 `flutter_localizations` + `intl`/`gen_l10n`（ARB，非自研）；Dart 侧 `EventBus` 作为应用层统一事件通道（引擎事件 + 本地事件），UI 不直连传输层
19. **桌面端 FFI 直连引擎（2026-08-07，取代 08-06 spawn+UDS 与更早侧车播放链路）**：Dart 加载 `libarchoera_mediaengine`，库内线程**全速完整转码 PCM 落盘 `stream.wav` → miniaudio 自播**（player 模式 `skip_encoder=true`，不再 Opus 编码）——「完整时长 + 任意 seek」语义；seek 走 miniaudio 即时 seek（不重启引擎、不重转码）；事件 FIFO 50ms 轮询 `pollEvent`（position 只留最新，`set_event_interval` 降频协商）；FFT 为拉模式（按播放位置从本地 PCM 索引读帧 + FFI libfft.so）
20. ~~sidecar 播放路径收窄~~（已随 2026-09-06 去侧车化整体废弃）
21. **内存播放（不落盘）模式（2026-09-08 决策；S1 引擎 C / S2 Dart 接线与设置已实现，S3 基准收尾待办）**：桌面播放**默认内存模式**（独立开关，与 Stable/EraAudio、SongCache 均独立）；解码 PCM 驻留进程内「全量块列表」（与 `stream.pcm` 文件块同构，达 cap 才滚动淘汰），频谱经新 FFI `archoera_mediaengine_pcm_window`/`_epoch` 拉窗，不写 `stream.wav/.pcm`；无设备 + 内存模式 → error（不文件回退）；`cap`：auto（按可用内存均衡，**0.8 GiB 硬上限**，查询故障回落、append 后记账强制淘汰、绝不越过用户设限）/ 自定义 / 无上限（须显式警告内存过载后果）。文件模式（设置关 / `ARCHOERA_ENGINE_FILE_MODE=1`）保留现状字节级行为。规格与验收：`docs/audio-memory-playback.md`。
