# ArchoeraMusic 架构规划

> 状态：规划稿 v3 · 2026-08-05
> **更正（2026-08-09）**：本文早期以「复用 SPlayer-Next `server/` 方案」为前提的规划描述，仅作为**历史背景参考**。实际开发中，所引用的服务端代码（Go Subsonic、C 音频引擎、C# 扫描、C++ 刮削、Rust 下载引擎等）均由本仓库作者**自行编写**，**不在 SPlayer / SPlayer-Next 主仓库内**；SPlayer-Next 与本项目**无代码归属关系**，本项目不包含其代码。
>
> 定位：独立开发的 Flutter 混合架构音乐播放器（桌面为主），以 AGPL-3.0 开源
>
> **核心原则：Flutter 承载 UI 与业务层，后端与原生工具链整体自行编写（C 音频引擎 / C# 扫描 / C++ 刮削 / Rust 下载 / Go Subsonic）。**

---

## 1. 项目定位

| 项 | 说明 |
|---|---|
| 名称 | ArchoeraMusic |
| 形态 | Flutter 桌面音乐播放器（Windows / macOS / Linux），**桌面为主** |
| 架构 | 混合架构：Flutter UI + Dart 业务层 + **Node 侧车（= server/ 方案）** + 多语言原生工具链 |
| 代码归属 | 全部自行编写（含所引用的服务端代码），不在 SPlayer / SPlayer-Next 主仓库内 |
| 开源 | 以 AGPL-3.0（`AGPL-3.0-or-later`，含后续版本弹性条款）发布（仓库根 LICENSE 已提供） |
| 第三方依赖 | KuGouMusicApi（MIT）、NeteaseCloudMusicApi 相关实现（MIT）、TagLibSharp、FFmpeg 等——保留第三方声明 |

**「让不同架构发挥最大效能」的具体分工：**

| 架构 | 承担 |
|---|---|
| Flutter / Dart | UI、动画、歌词渲染、状态管理、窗口；**媒体渲染端**（libmpv 播放 OGG/Opus 流） |
| TypeScript（server/）| 平台 API 协议/加密、SQLite 数据层、业务路由、子进程调度、**播放服务（引擎生命周期管理）** —— 原样复用，不重写 |
| C | **统一音频引擎（主引擎）**：FFmpeg 解码 + EQ/响度/限幅/FFT/变速变调 + Opus 编码（`archoera-audio-engine`）|
| C# | 音乐库扫描（TagLibSharp，`archoera-scanner`） |
| C++ | 元数据刮削（多源并发，`archoera-scraper`） |
| Rust | 下载引擎（CLI `archoera-downloader`）、`tempo-rs`（变速变调静态库，C 引擎内置）、媒体控制/任务栏歌词（napi，Phase 3）|
| Go | Subsonic 协议层（自用桌面端可选启用） |

> **音频架构要点**：桌面端与 Web 端共用**同一条 C 引擎管线**（`archoera-audio-engine`），
> Flutter 只做"媒体渲染端"——播放侧车推送的 OGG/Opus 流（libmpv 解码出声），
> 全部 DSP（EQ/响度/FFT/变速变调）在 C 引擎内完成。
> Rust `native/audio-engine`（napi 直出）**不在 ArchoeraMusic 引入**，仅留在 SPlayer-Next 桌面端使用。

**核心处理逻辑技术选型原则**
- **默认复用优先**：TS（sidecar）承担平台协议 / 路由 / 数据库 / 编排；原生工具链承担重型处理（C 音频引擎、C# 扫描、C++ 刮削、Rust 下载）
- **必要时允许 C/C++（含 Node GC 考量）**：Node 为长驻进程，V8 GC 弱点是老生代高水位、STW 停顿与对象碎片化；当模块命中以下任一特征时，可重构为 C/C++ 并经 sidecar 以**子进程 CLI**（现有模式）或 **FFI**（napi / Phase 4 FFI 直连）调用：
  - 高频小对象 / JSON 编解码密集（GC 压力大）
  - 大缓冲流式转发（external / `Buffer` 反复拷贝）
  - CPU 密集（加密、格式转换、批量处理）
  - 常驻大对象缓存（LRU 命中路径）
- **下沉决策流程（证据驱动，避免过度重构）**：`profile（内存基线 / CPU 热点 / GC 停顿）→ 命中阈值 → 只下沉该模块 → 回归对比`；server 现有 `utils/memory.ts` 仅监控（RSS/heap/external，2min），GC 由 V8 `--max-old-space-size` 自动管理——下沉前以此为基线
- **候选下沉点（按需启用，不主动重写）**：
  - 歌词/字幕解析与标准化（KRC/QRC/YRC…——字符串高频小对象）
  - CUE 分轨（`cue.ts`）
  - netease weapi/eapi 加解密（AES-128-CBC + RSA → OpenSSL C++）
  - audio 流式转发（OGG 字节流拷贝）
  - tag 编辑（C++ TagLib 已有）、loudness 分析（scanner 侧已有）

---

## 2. 链路复用映射（server 方案 → ArchoeraMusic）

> SPlayer-Next 的 `server/` 是一个**自包含的多语言后端**：Hono + better-sqlite3 + esbuild 单入口，
> 通过 spawn 子进程调度 C/C#/C++/Rust CLI，所有 SQLite 写入经 `/api/db/*` 代理串行化。
> 该方案与 Electron/Vue 无耦合，天然可作为 Flutter 的后端进程直接复用。

| 链路 | server 实现 | 复用方式 |
|---|---|---|
| 在线平台 API | `apis/netease|kugou|qqmusic/`（core + modules + 注册表 + 公共缓存）| **Dart 移植**（`app/lib/core/apis/`，纯 Dart 直连；sidecar `/api/proxy` 已下线） |
| 歌词 | `apis/common/lyric/`（kugou/netease/qqmusic/ttml 统一管道）+ `routes/lyric.ts` | **Dart 移植**（`app/lib/core/apis/lyric/`，纯 Dart 直连；sidecar `/api/lyric` 已下线） |
| 音乐库 | `database/`（queries/scanner/migration）+ `music/`（scanner/watcher/serve/organizer）| **直接复用** |
| 扫描 | C# `archoera-scanner`（TagLibSharp + SqliteDirectWriter）| **直接复用**（子进程 + `/api/db/*`） |
| 刮削 | C++ `archoera-scraper`（多源 + 评分合并 + TagLib 写入）| **直接复用**（子进程 + `/api/db/*`） |
| 下载 | `routes/download.ts` + Rust `archoera-downloader` CLI | **直接复用** |
| 配置 | `config/store.ts` + `routes/config.ts` | **直接复用** |
| 会话/凭据 | `database/sessions.ts`（平台 cookie）| **直接复用** |
| 转码串流 | C `archoera-audio-engine` + `routes/audio.ts`（OGG/Opus）| **主引擎**：全部播放经此管线（详见 §5） |
| 音频控制 | `routes/audio.ts`（`/api/audio/control/:id` 运行时控制）| **直接复用** + 扩展 `seek` |
| 音频事件 | `routes/ws.ts`（`audio:subscribe` FFT 广播）| **直接复用** + 扩展 player 事件 |
| Subsonic | Go `subsonic/`（:8081，TS 反向代理）| 桌面自用默认**不启用**，预留开关 |
| 播放（桌面） | 原项目为 Rust napi `audio-engine`（Electron 主进程内加载）| **不引入**；桌面统一走 C 引擎 + libmpv 渲染 |
| 缓存 | `routes` 静态 `/api/cache/*`、封面/歌手缓存目录 | **直接复用** |

**结论**：ArchoeraMusic 的「后端」不是重写 sidecar，而是**以 `server/` 为单进程后端**（fork/复制为 `sidecar/` 目录，随 SPlayer-Next 维护同步），Flutter 只是它的又一个 HTTP/WS 客户端。

---

## 3. 进程模型

```
┌───────────────────────────────────────────────────────────────────┐
│ Flutter App（单可执行文件）                                          │
│  ┌───────────────────────────────────────────────────────────────┐ │
│  │ UI 层（Dart）：主窗口 / 歌词窗口（桌面歌词·动态岛·任务栏）        │ │
│  ├───────────────────────────────────────────────────────────────┤ │
│  │ 业务层（Dart，Riverpod）：播放控制 · 歌词同步 · 队列/历史 · 主题   │ │
│  ├───────────────────────────────────────────────────────────────┤ │
│  │ 桥接层：                                                       │ │
│  │  · api_client（HTTP，localhost）→ 侧车                          │ │
│  │  · ws_client（WebSocket 事件订阅）→ 侧车                        │ │
│  │  · 媒体渲染端（libmpv 播放 OGG/Opus 流，media_kit）             │ │
│  │  · ProcessManager（spawn 原生子进程，备用路径）                  │ │
│  └───────────────────────────────────────────────────────────────┘ │
└──────────────────────────┬────────────────────────────────────────┘
                           │ spawn（嵌入式 Node）
┌──────────────────────────┴────────────────────────────────────────┐
│ Node 侧车（= server/ 的 dist/index.js + node_modules + 二进制）     │
│                                                                   │
│  Hono HTTP（/api/*）+ WebSocket（/ws）                              │
│  ├─ apis/netease · kugou · qqmusic + common/lyric                 │
│  ├─ routes/  proxy · lyric · music · download · config · db · ws   │
│  ├─ database/  better-sqlite3（library.db WAL）                    │
│  ├─ store / config / utils / events                                │
│  ├─ 子进程调度：                                                   │
│  │   ├─ spawn archoera-scanner        （C#，stdout JSON lines）     │
│  │   ├─ spawn archoera-scraper        （C++，stderr 标记行）         │
│  │   ├─ spawn archoera-downloader     （Rust CLI，stdout 进度）     │
│  │   ├─ spawn archoera-audio-engine   （C，主音频引擎，见 §5）         │
│  │   └─（可选）spawn Go subsonic :8081                             │
│  └─ napi 加载（Phase 3+）：media-ctrl / taskbar-lyric│
└────────────────────────────────────────────────────────────────────┘
```

**与 SPlayer-Next 的对应关系：**

| SPlayer-Next | ArchoeraMusic |
|---|---|
| Electron 主进程（壳 + IPC + napi 加载）| Node 侧车（加载 napi + spawn 子进程）|
| Vue 渲染层（web/）| Flutter UI |
| Pinia stores / services/ | Riverpod / Dart 服务层 |
| preload + IPC | 桥接层（HTTP + WS + 媒体渲染端 libmpv）|
| 歌词独立窗口（windows/）| Flutter 多窗口（桌面歌词等）|

---

## 4. Node 侧车 = server/ 方案（详细）

### 4.1 载体选择
| 方案 | 说明 | 倾向 |
|---|---|---|
| **复制 server/ 为 sidecar/** | fork `server/`（TS + 配置 + build.mjs），独立 npm 包；随上游 SPlayer-Next 定期同步 | ✅ 推荐 |
| 作为 monorepo 子包依赖 | 需要跨仓库共享，当前两个仓库独立，复杂度高 | ✗ |

> `sidecar/` 与 SPlayer-Next `server/` 保持同构；同步方式：定期对比 diff 手动合并（后续可上脚本）。

### 4.2 构建与打包
- 沿用 `server/build.mjs`（esbuild ESM 单入口，`@main`/`@shared` 别名，原生依赖 external）
- Node 运行时：**官方 Node 二进制 + 压缩 bundle**（Phase 1 起步）；后续评估 **Node SEA** 单文件化
- 原生二进制（`archoera-scanner` / `archoera-scraper` / `archoera-downloader` / `archoera-audio-engine`）：三平台构建脚本，随 app 打包分发

### 4.3 进程生命周期
- Flutter 启动 → `Process.start(node, [bundle/index.js, --port, ...])` → 轮询 `/api/health` 就绪
- 随机端口 + 仅监听 127.0.0.1 + 启动 token（argv 传入，请求头校验）
- 退出：Flutter 发 SIGTERM → server 优雅关闭（停 watcher、关数据库、SIGTERM 子进程树）
- 崩溃：检测到进程退出 → 弹提示 + 可自动重启
- 数据目录：`{appData}/ArchoeraMusic/`（`database/`、`cache/`、`logs/`、`config/`，沿用 server 的 paths 约定）

### 4.4 侧车内部结构与 server/ 一致
```
sidecar/
├── index.ts                # Hono 入口 + 路由挂载 + WS + 静态文件
├── store.ts · config/      # 配置存储
├── build.mjs · package.json · tsconfig.json
├── database/               # index / migration / queries / sessions / downloads / lyricCache(+Match/Ttml)
├── music/                  # scanner（C# 调度）/ scraper（C++ 调度）/ watcher / serve / organizer
├── routes/                 # proxy / lyric / music / config / download / db / ws / audio / comments / admin
├── apis/
│   ├── common/cache.ts     # LRU + TTL + 并发去重
│   ├── common/lyric/       # kugou / netease / qqmusic / ttml / utils
│   ├── netease/            # core（crypto/request/xeapi/cookie/device/option/ncbl/types/config/cache）
│   │                       # modules（~80：登录/歌单/云盘/评论/FM/搜索/歌词/专辑/歌手/榜单…）
│   ├── kugou/              # core（config/krc/request/types）+ modules（search/lyric，扩容计划见 §8）
│   ├── qqmusic/            # core（qrc/tripledes/request/config/types）+ modules（8）
│   └── musicbrainz.ts
├── utils/                  # logger / config / crypto / events / paths / protocol / stream
└── dist/                   # esbuild 产物（随包分发）
```

### 4.5 侧车新增/调整（相对 server/ 的最小改动）
1. **播放服务**（新增 `services/player.ts`）：统一管理 C 引擎实例生命周期——load 时按当前效果配置 spawn 引擎、seek 时以新 offset 重启引擎、切歌时 SIGTERM 旧引擎（引擎已有优雅关闭）；维护"播放器状态"（eq/volume/normalization/limiter/tempo/fft/bitrate），供新引擎实例继承
2. **`seek` 控制**：`/api/audio/control/:id` 增加 `{"type":"seek","position_ms":N}`；实现方式 = 重启引擎（`--offset N` + 继承效果配置），Flutter 端重新拉流（详见 §5.3）
3. **WS 协议扩展**：现有 /ws 已有扫描/下载/FFT 广播，增加 `player:*` 事件通道（stateChanged/ended/sourceError/status）
4. **媒体同步**（Phase 3）：media-ctrl napi 在侧车加载，位置/状态同步（对齐原 main 的 services/media.ts）
5. **配置迁移**：desktop 特有配置项并入 server 的 `config/store`（如播放器设置、歌词设置），Flutter 经 `/api/config/*` 读写

---

## 5. 音频播放链路（决策细化）

> **决策：以 C 引擎 `archoera-audio-engine` 为统一主引擎**，桌面与 Web 共用一条音频管线。
> Flutter 只做媒体渲染端（libmpv 播放完整转码 OGG）；EQ/响度/限幅/FFT/变速变调全部在 C 引擎内完成。
> 桌面端 Flutter 经三路 UDS 直连引擎（§5.1）；Web 端经侧车播放服务（保留）。
> Rust `native/audio-engine`（napi 直出）**不引入** ArchoeraMusic（仍留在 SPlayer-Next 桌面端维护）。

### 5.1 链路总览（桌面端直连引擎，2026-08-06 落地）

```
歌曲源（在线 URL / 本地文件 / 音乐库 trackId）
  → Flutter 直连 spawn archoera-audio-engine <source> [--eq --preamp --normalization
      --limiter --tempo --fft --keep-alive-ms]   （效果配置从播放器状态继承；桌面端不经侧车）
  → C 管线：decode → resample → eq → loudness → limiter → tempo → fft → Opus encode → OGG
  → 三路 UNIX 域套接字（UDS）：
      stream.uds  → OGG 流 → OggFileSink 落盘 stream.ogg（全速完整转码）
      pcm.uds     → 原始 float PCM 块 → PcmAnalyzer 落盘 + pos 索引
      control.uds → 控制事件 JSON 行（ready/status/done/error）→ EngineEvent
  → 转码完成（done）→ libmpv 直接播放本地完整 stream.ogg（恢复原 SPlayer-Next 行为：
      完整时长、任意位置 seek）
  → seek：libmpv 本地 seek（不重启引擎、不重转码）
  → FFT：UI 按播放位置从本地 PCM 索引按需读帧 → libfft.so（FFI）分析 → 128 bins（拉模式，§10.1）
  → 事件：ready / status / done / error → control.uds → Dart EngineEvent
```

**Web 兼容路径（保留）**：侧车播放服务 `services/player.ts` + `/api/audio/stream` + WS `audio:*`；binding 归位 `sidecar/audio-engine/binding.ts` 可独立构建，桌面端不再调用。

### 5.2 媒体渲染端选择（Flutter 侧）

| 方案 | 说明 | 倾向 |
|---|---|---|
| **media_kit（libmpv）** | OGG/Opus/HTTP 流解码成熟；seek/音量/速度原生支持；三平台一套 API | ✅ 首选 |
| just_audio + just_audio_mpv | 同上（同为 libmpv），API 更简单但灵活性低 | 备选 |
| 纯 Dart 解码（ogg/opus 包）| 无系统依赖，但需自建音量/变速/同步，工作量大 | ✗ |

> media_kit 三平台额外体积约 20~50MB（含 libmpv），自用桌面可接受。

### 5.3 关键控制流（桌面端直连）

**Seek**：完整转码落盘后由 **libmpv 本地 seek**（`player.seek`）——不重启引擎、不重转码、无毛刺（2026-08-06 落地，取代原「重启引擎 + `--offset`」方案）
**EQ/音量/变速变调实时调整**：引擎 stdin JSON 命令（交互模式已有）——Flutter `AudioEngineProcess.sendCommand` 直连调用
**FFT 频谱**：PCM UDS → 本地落盘索引 → 按播放位置 `frameAt(pos)` 按需读帧 → FFI `libfft.so`（拉模式，§10.1）
**进度/状态**：`get_status`（交互模式已有）+ libmpv 自身 position 双源
**切歌**：旧引擎 SIGTERM（优雅关闭已有）+ 新引擎 spawn；预加载下一首为 Phase 3 优化项

### 5.4 音质与带宽策略

**统一 Opus 转码（在线与本地同管线）**

| 场景 | 输出格式 | 说明 |
|---|---|---|
| 在线音源 | Opus（QualityLevel 映射：`hi-res` 256 / `lossless` 192 / `hq` 128 / `sq` 96 / `lq` 64 kbps）| 有损重编码可接受，Opus ≥192kbps 听感透明 |
| 本地文件 | Opus（建议 `lossless` 192kbps+ 或 `hi-res` 256kbps）| 与在线共用一条管线、一个输出格式；CPU/带宽均无压力 |

- **本地走转码无额外成本**：音频级处理单核实时因子 5~10x+；本地播放不经外网，不受带宽限制
- **音质说明**：转码只作用于播放路径（播放时有损），**曲库磁盘文件保持无损原样**；Opus ≥192kbps 听感透明
- **seek**：完整转码 + libmpv 本地 seek（§5.3），与在线一致，无毛刺

**FLAC/raw PCM 直通模式（保留，可选）**
- C 引擎编码阶段保留无损输出模式（FLAC / raw PCM），管线 DSP（EQ/响度/限幅/FFT/tempo）完全复用
- 用途：本地 bit-perfect 回放（当用户选择"无损模式"时切换；默认仍统一 Opus）
- 实现成本低：编码器抽象已存在，替换编码器即可；libmpv 播 FLAC 无需 Range

**FFT 与输出格式无关**
- 管线顺序 `decode → resample → eq → loudness → limiter → tempo → **fft** → encode`：FFT 分析在编码**之前**
- 数据链路：引擎 fd4（JSON 行）→ 侧车 → WS `audio:subscribe` → Flutter 频谱渲染——与输出 Opus/FLAC 无关，零改动

**带宽分析（在线场景）**
- 外网带宽只消耗在**源下载**；转码输出流走 localhost 回环，不计入外网
- 量级：Opus 192kbps ≈ 24KB/s（2Mbps 的 ~10%）；即使音源 FLAC ~1Mbps 也仅占 2Mbps 的一半
- **降级策略**：播放服务监控源下载速率，当源下载速率低于消费速率（网络抖动/快进追赶）时，自动降级输出 bitrate（如 192→128kbps）并重启引擎，将"转码输出"与"源下载"解耦，保证播放平滑

### 5.5 播放控制语义（对齐 SPlayer-Next，桌面端直连）
```
load(track) → Flutter spawn 引擎（直连三路 UDS）→ 完整转码 → done → libmpv 播放本地完整文件
play / pause / stop / seek(sec)          （seek 走 libmpv 本地 seek；pause 走 libmpv）
setVolume / setFadeDuration              （libmpv 侧音量；引擎 preamp 管余量）
setEqualizerEnabled / setEqualizerBands / setPreampGain   → 引擎 stdin set_eq
setNormalizationEnabled / setFftEnabled / getFftData(128)  → 引擎 stdin set_* + 本地 FFT（§10.1）
setSpeed / setPitch / setPitchSync       → 引擎 stdin set_tempo_*（重启生效）
事件：stateChanged / ended / sourceError / position / fftData / outputStalled
```
> 高频推送遵循原项目「隐藏即静默」：频谱不可见时不推 FFT；歌词窗口隐藏时不推位置。

### 5.6 C 引擎 spawn 参数与设置映射（可执行清单）

**spawn 参数表**（`archoera-audio-engine`，参数与引擎 `--help` 一致）

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
| `--keep-alive-ms <n>` | 0 | 转码完成（EOF）后保持进程存活 n ms 等待迟到消费者；桌面端用（默认 10s），避免短音频 done 前消费者未连上 |
| `--stream-uds <path>` | — | OGG/Opus 流输出到 UDS（替代 stdout，桌面端）；引擎**等待消费者连上（15s）后才开始转码**，保证 OGG 从头完整 |
| `--pcm-uds <path>` | — | 原始 float PCM 块输出到 UDS：`[pos_ms|samples|channels] + float`（小端，4096 samples/帧），供 FFT 拉模式（§10.1） |
| `--control-uds <path>` | — | 控制事件 JSON 行输出到 UDS（替代 fd3；Dart `Process` 无法传额外 fd，桌面端必用）；`control_send_line()` 优先 UDS，否则 fd3（Web 兼容） |
| stdout / stderr | — | 无 UDS 时 OGG/Opus 走 stdout（Web 兼容）；stderr 日志 |

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
| 音量 volume | — | `set_volume {gain}`（主音量在 libmpv 侧，preamp 管余量） |
| 响度归一化 | `--normalization` | `set_normalization {enabled}` |
| 限幅器 | `--limiter-threshold`（默认启用） | `set_limiter {enabled}` |
| 频谱显示 | `--fft` | `set_fft {enabled}` |
| 变速/变调 | `--tempo --tempo-speed --tempo-pitch` | `set_tempo_speed` / `set_tempo_pitch` |
| seek | —（桌面端 libmpv 本地 seek，§5.3）；`-o --offset`（Web 兼容：重启引擎） | `seek {position_ms}`（进程内，Phase 3+） |

---

## 6. 原生子进程工具链（复用清单）

| 二进制 | 语言 | 调用方 | 协议 |
|---|---|---|---|
| `archoera-scanner` | C#（TagLibSharp）| 侧车 spawn | stdout JSON lines 进度；`POST /api/db/upsert*` 写库 |
| `archoera-scraper` | C++（libcurl + TagLib）| 侧车 spawn | stderr `[done N/Total]`；`POST /api/db/scrape/batch` |
| `archoera-downloader` | Rust（reqwest）| 侧车 spawn | stdout JSON 进度；`POST /api/db/download/*` |
| `archoera-audio-engine` | C（FFmpeg + libopus）| **主引擎**（侧车 spawn）| stdout OGG/Opus；交互模式 fd3 控制 / fd4 FFT；SIGTERM 优雅关闭 |
| `tempo-rs` | Rust（signalsmith-stretch）| 静态链接进 C 引擎 | C FFI（`HAS_TEMPO` 条件编译）|
| Go `subsonic` | Go | 侧车 spawn（可选）| HTTP :8081，TS 反向代理 `/rest/*` |

**SQLite 写入规范（沿用）**：所有写入必须经 `POST /api/db/*` 由 TS 层代理（better-sqlite3 同步串行），禁止其他进程直写，避免 `SQLITE_BUSY`。

---

## 7. 平台 API 接入

### 7.1 Netease（首期，server 已全量内置）
`sidecar/apis/netease/` 直接来自 server，无需重写：
- `core/`：weapi/eapi/linuxapi 加解密、request（国内 IP 池）、xeapi、device、cookie、option、ncbl、config、cache
- `modules/`：**全量 ~80 个**——登录（cellphone/QR/token/refresh/logout/status）、歌单（detail/tracks/create/delete/subscribe/update）、云盘（upload/check/nos/pub/import/lyric）、评论（hot/music）、FM、搜索（suggest/hot/multimatch/match）、歌词（lyric/lyric_new）、专辑/歌手、榜单、每日推荐、用户（account/detail/level/record/playlist/follows）等
- `index.ts`：`callNetease(name, params)` + 会话缓存 + 登录态变更回写 `sessions` 表
- 登录：二维码（login_qr_create/key/check）→ Flutter 展示二维码 + 轮询

### 7.2 KuGou（首期）
1. **更新克隆**：`KuGouMusicApi/` = MakcRe/KuGouMusicApi **v1.5.1（2026-02-05）手动拷贝**（非 git 仓库）；上游 main 分支持续更新（2026-08-05 仍有提交），确认落后。本机可直连 GitHub。
   - 操作：`git clone https://github.com/MakcRe/KuGouMusicApi.git` 到工作区替换旧目录，保留旧目录做 diff 参考
2. **提取核心**：`util/crypto.js`（token/签名）、`util/request.js`、`util/runtime.js`、各 `module/*.js`（160+ 端点）逻辑
3. **移植进模块架构**：以现有 `sidecar/apis/kugou/`（search/lyric 已可用）为起点，按需从 KuGouMusicApi 补：
   - `song_url`（音源 URL）、`rank_list`/`rank_info`（榜单）、`playlist_detail`/`sheet_*`（歌单）、`search_suggest`、`comment_*`、`login*` 等
   - 注意 `platform` 完整版 vs `lite` 概念版 token 不通用，自用选定一版并在 modules 内封装隔离
4. KRC 歌词解析：已有 `core/krc.ts`（KRC → 标准时间轴），直接复用

### 7.3 QQ Music（后期）
- `sidecar/apis/qqmusic/` 直接复用 server（TripleDES + RC4 + qrc 加密、match/search/lyric/leaderboard/hot_search/song_info/song_list）

### 7.4 登录与会话管理
- **会话持久化**：各平台登录成功后 cookie 写入 `sessions` 表（`database/sessions.ts`，已复用），重启不丢
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
| 平台会话 cookie / 下载任务 | `sessions` / `downloads` 表 | 遗留说明：历史架构侧车表，当前桌面端已去侧车化，由 Dart 本地层承接 |
| 配置 | `config/settings.json`（原子写 + 迁移）| Dart |
| 队列 / 播放历史 / UI 偏好 | Dart 本地（drift 或 Hive）| Flutter |
| 日志 | `logs/` | 各进程各自 |

**拆分原则**：媒体库（高频读写、多进程共享、无敏感数据）与用户数据（低频、含凭据、需加密）物理隔离——
- 用户库路径 `dataDir/database/user.db`，与媒体库同目录独立文件，密钥自举到 `dataDir/secret.key`；
- 旧版（library.db 内嵌 subsonic_* 表）数据在服务端启动时经 `MigrateUserDB` 自动迁移到 user.db 并删除媒体库旧表（幂等，密文原样搬运不重加密）；
- scanner 直写媒体库、subsonic 服务端直读直写媒体库与用户库、前端读媒体库的四方访问模型保持不变。

---

## 9. 通信协议（桌面端零 TCP 端口）

**原则**：桌面端**不暴露任何 TCP 端口**——控制面走 stdin/stdout JSON-RPC，媒体面由引擎三路 UNIX 域套接字承载（Flutter 经 dart:io UDS 直连；完整转码落盘后 libmpv 播放本地文件，不再需要媒体口 HTTP 流）。

| 通道 | 内容 | 端口占用 |
|---|---|---|
| **控制面：stdin/stdout JSON-RPC（Phase 1 桥接改造）** | Flutter ↔ 侧车全部 API 调用与事件推送（登录/搜索/歌词/曲库/配置）。**RPC 适配器复用 Hono `app.request()` 映射既有路由（路由零改动）**；stdout 行协议推送事件；`ping` 替代 `/api/health` | **无** |
| **引擎控制：control.uds** | Flutter ↔ C 引擎控制事件 JSON 行（ready/status/done/error）——引擎 spawn 直连（不经侧车，§5.1） | **无（UDS）** |
| **引擎媒体：stream.uds / pcm.uds** | 转码 OGG 流与原始 float PCM 块 → 本地落盘（完整文件）→ libmpv 播放 / FFT 按需读帧（§10.1） | **无（UDS）** |
| HTTP 其余路由 | 仅作 RPC 适配器的内部复用载体（经 `app.request()` 调用），桌面端不直接暴露 | 无 |
| WS `/ws` | 桌面端**停用**（事件改走 stdout RPC + control.uds）；保留为 Web 兼容路径 | 无 |
| 子进程 stdio | C#/C++/Rust CLI 进度（沿用）；C 引擎 stdin 命令 + fd3/fd4（Web 兼容路径沿用） | 无 |

**安全**：桌面端零 TCP 端口；UDS socket 文件置于会话私有目录（`/tmp/archoera-{host}-{pid}-{ts}/`，0700）；侧车控制面无端口，天然不可从外部访问。

**为何不再需要媒体口**：旧链路受「增长中文件 EOF / Dart 管道流无法喂 libmpv」约束而保留 loopback 单口；现改为**完整转码落盘**（引擎全速、done 后文件就绪，无 EOF 问题），libmpv 直接播放本地完整文件——loopback 端口与 `unix://` 探索均不再需要。Web 兼容路径（侧车 `/api/audio/stream`）保留于 sidecar。

---

## 10. Flutter 层设计

- **窗口**：Phase 1 单主窗口；歌词窗口（桌面歌词/动态岛）Phase 3 用 `desktop_multi_window` / 平台壳多窗口
- **状态管理**：Riverpod；**路由**：go_router
- **i18n（Flutter 原生，非自研）**：`flutter_localizations` + `intl`/`gen_l10n`（ARB 管道）——复用原项目 8 语言文案，首期 zh-CN / en-US，其余后续补；侧车侧沿用 server `utils/i18n.ts`
- **事件总线（Dart 侧统一事件通道）**：`EventBus`（StreamController 多路复用）承载两类事件——侧车事件（经 RPC 适配器转译，`player:*`/`audio:fft`/扫描/下载进度）与本地事件（播放队列、UI 状态）；UI 层只依赖总线，不直连传输层
- **主题**：亮/暗 + 封面动态取色
- **核心页面**：搜索、歌单/榜单、播放页（滚动歌词 + 频谱）、队列、设置、登录（二维码）、音乐库（Phase 3）、下载（Phase 3）
- **歌词渲染**：自绘文本行，沿用原项目时间轴插值/锚点算法；格式解析（LRC/YRC/KRC/QRC/TTML）优先复用侧车歌词管道返回的标准化数据
- **播放控制**：`PlaybackController`（Dart）封装 §5.2 语义，播放走直连引擎（§5.1），业务 API 桥接到侧车
- **桌面集成（Phase 3+）**：媒体键、系统托盘、全局快捷键、任务栏缩略图——通过侧车内 media-ctrl / 平台壳插件

### 10.1 音频频谱（FFT 可视化）

**数据链路（桌面端：UDS PCM → 本地索引 → 拉模式，2026-08-06 落地）**

```
C 引擎 fft 阶段（管线内 DSP 之后、编码之前，与输出 Opus/FLAC 无关，见 §5.4）
  └─ pcm.uds（原始 float PCM 块：[pos_ms|samples|channels] + float，4096 samples/帧）
        → PcmAnalyzer 落盘 stream.pcm + (posMs → fileOffset) 内存索引
        → UI 按 media_kit 实际播放位置 frameAt(posMs) 二分定位 → 按需读文件
        → FFI libfft.so（fft_process_multi / fft_get_spectrum_norm_stereo）→ 128 bins
        → 频谱组件（CustomPainter，RepaintBoundary 局部重绘）
```
- **拉模式原因**：引擎全速转码可快于实时，UI 必须以播放位置取帧而非顺序消费；任意位置（含回退 seek）可回溯
- 引擎转码期间即可用（缓冲已落盘的块）；帧间插值沿用原 BottomSpectrum.vue 算法（见下）
- Web 兼容路径沿用引擎 fd4 JSON 行 → 侧车 → WS `audio:subscribe`

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
- 配置映射：`enableSpectrum` / `spectrumBarWidth` / `spectrumDisplayMode(mirror|split)`——并入侧车 `config/store`，Flutter 经 `/api/config/*` 读写

**节能（隐藏即静默）**
- 桌面端：频谱可见才开启 `_pollSpectrum` Ticker，不可见停止轮询；本地文件拉帧无订阅/推流开销，「隐藏即静默」= 停止 UI 轮询
- Web 兼容路径沿用 acquire/release 严格配对（参照 Web 端 `acquireFft()/releaseFft()`）

**实现（2026-08-06 已落地）**
- `pcm_analyzer.dart`：PCM 落盘 + 二分索引；`frameAt(posMs)` 按需读文件做 FFT（长音频零内存全量缓冲）；`isDone/bytesIn/frameCount` 诊断字段
- `fft_bindings.dart`：`FftAnalyzer` FFI 封装（`fft_set_enabled(1)` 显式；缓冲 fftSize×32 修复段错误）
- `playback_notifier.dart`：`_pollSpectrum()` 按 `state.position` 每 50ms 拉帧；`PlaybackState.fft`（`FftFrame{ldata,rdata}`，copyWith 哨兵支持置空）；`stop()` 清空 `state.fft`
- `widgets/spectrum_view.dart`：CustomPainter + Ticker（~16ms 重绘）复刻 `BottomSpectrum.vue`——帧间插值、ATTACK 0.4/DECAY 0.88、SKIP_LOW=8、双声道镜像拼接（左倒序 + 右正序，usableLen 240）、bar 空间平滑（±1 邻居）、barWidth 4/gap 3/radius 2、底部对齐
- 消费端：播放页大频谱 + 播放条迷你频谱；`stop()` 清空 `state.fft`（频谱归零）
- 已验证：AUTOPLAY 全链路 `FFT 频谱已启动: 本地 N 帧 @50ms 拉模式`；440Hz 校准 `bin67 val=0.793`

### 10.2 歌词流水线（获取 → 匹配 → 标准化 → 渲染）

**获取（2026-08-07 已变更：纯 Dart 直连，不经 sidecar）**
- `app/lib/core/apis/` 全量移植：netease（73 模块 + xeapi/ncbl）、qqmusic（含 QRC 3DES 解密）、kugou（含 KRC 解密）、`lyric/` 匹配层（fingerprint/pickBestCandidate/ttml）；sidecar `/api/proxy`、`/api/lyric` 已下线，`routes/proxy.ts`、`routes/lyric.ts` 已删除
- 侧车端点（已下线，原设计）：`/matchById {platform,id}`、`/matchByQuery {platform,track}`（按平台返回**原始歌词文本**）、`/ttml {track,platform}`（netease/qqmusic 在线 TTML overlay，含翻译）
- **多源回退由前端编排**（对齐原项目 `services/lyric/resolve.ts`）：按设置 `lyricSourceOrder`（源顺序，可配置）+ `lyricFormatOrder`（格式优先级）+ `smartPreferOnline` 逐源尝试；命中 `lyricMatchCache`（track 指纹）
- **缓存**：`lyricMatchCache`（歌曲指纹 → 命中源）、`lyricCache`（原始歌词）、`lyricTtmlCache`（TTML overlay）

**标准化（新增 sidecar 端点，纯 TS 复用）**
- 原项目 Web 端 `src/utils/lyric/parse*.ts`（LRC/KRC/QRC/YRC/ASS/SRT/TTML + normalize）与 `resolve.ts` **全是 TS 代码 → 直接整体移入 sidecar**，新增 `/api/lyric/resolve` 返回统一行数组 `{ time, text, translation, emphasis, interlude }`
- KRC（`core/krc.ts`）、QRC（`core/qrc.ts`）、服务端 TTML（`ttml.ts`）均可复用，统一走 resolve 输出
- **结果：Flutter 零解析负担**，只消费标准化行数组

**渲染（Flutter）**
- **歌词引擎 Dart 移植（重点工程）**：原项目 `Lyrics/engine/`（AMLL：line-builder / word-builder / spring / line-animations / emphasize / interlude / scroll-preroll / split-words）→ Apple Music 风格逐字/逐词高亮动画、弹簧曲线、间奏处理（详见 §10.7）
- 翻译行：双行模式（原文 + 译文），可开关
- 无歌词回退：显示"纯音乐 / 无歌词"状态
- **歌词窗口（Phase 3）**：独立窗口经控制面 RPC 事件 `player:position`（「隐藏即静默」——窗口不可见不推送）同步，避免高频 IPC

### 10.3 播放队列与播放模式

- **归属**：队列 / 播放历史 / UI 偏好存 **Dart 本地**（drift 或 Hive，§8）；业务数据（曲库/统计）在侧车
- **模型**：`nextQueue` + `prevHistory` + 当前索引；`PlaybackController` 管理
- **播放模式**：顺序 / 列表循环 / 单曲循环 / 随机（复用原项目语义，随机种子可复现）
- **切歌流程**：next/prev → `load(track)` → Flutter 换引擎（SIGTERM 旧 + spawn 新，继承播放器状态）→ 完整转码 → libmpv `open(新文件)`
- **播放统计**：每曲播放完成写侧车 `playStats` 表（复用查询/迁移）；Last.fm scrobble 可选（Phase 3，复用 `apis/lastfm` 思路）

### 10.4 播放容错与降级

| 场景 | 检测 | 处置 |
|---|---|---|
| 源失效（404/403/超时）| 引擎 stderr 错误 → control.uds `EngineError`（Web 兼容路径为侧车 `player:sourceError`） | 可选**自动换源**：以该曲目在另一平台的搜索匹配结果重取 URL 重载（自用增强，可关） |
| VIP/受限音质 | 音源返回受限码/低 bitrate | 正常播放 + UI 显示"受限音质（如 128k）"来源标记，不自动跳转 |
| 网络抖动/断流 | libmpv `outputStalled` + 引擎暂停输出 | 带宽降级（§5.4）；重试失败 → 暂停 + 提示 |
| 登录态过期 | 播放 403/401 | 提示重新登录（二维码），恢复后继续 |
| 歌词源缺失 | `/api/lyric` 全源 miss | 显示"无歌词"，不影响播放 |

- 统一驱动：所有异常走 WS `player:*` 事件（stateChanged/sourceError/status），Flutter 单一状态机消费

### 10.5 桥接层细节（Dart）

- **rpc_client**（控制面，侧车 API 调用）：stdin 写 JSON-RPC 请求（`{id, method:"GET|POST", path, body}`），stdout 读响应与事件行；内部复用 Hono `app.request()`（侧车侧，路由零改动）；幂等 GET 指数退避重试（≤3 次）；统一错误模型 `ApiException(code, message)`；事件经 EventBus 分发（§10 导语）
- **audio_engine_process**（引擎直连，2026-08-06）：spawn 引擎 + stdin JSON 命令；等 3 个 socket 文件出现（8s）→ 并发连接 control.uds / pcm.uds / stream.uds；`EngineEvent`（ready/status/done/error/exited）；`done` Completer（转码完成 = OGG/PCM 文件就绪）；`stop()` = 关桥 → SIGTERM → 5s SIGKILL + 删会话目录；sessionId = socket 目录名
- **ogg_stream_bridge → OggFileSink**（媒体面）：stream.uds → `stream.ogg` 落盘（IOSink 非 `StreamConsumer<Uint8List>`，手动 listen 累积，不可 pipe）
- **media_renderer**（libmpv 封装）：播放**本地完整 OGG 文件**（替代旧链路媒体口 HTTP 流）；状态机 `idle → loading → playing → paused → ended/error`；position/duration 事件回灌 `PlaybackController`；`seek()` 本地 seek
- **进程生命周期**：App 退出 → 引擎 SIGTERM → 侧车 SIGTERM → 等待 exit（超时 5s 强制）；崩溃检测 → 提示 + 自动重启（§4.3）

### 10.6 桌面配置清单（并入侧车 `config/store`，desktop 分组）

| 分组 | 配置项（示例） |
|---|---|
| 播放器 | 音量、淡入淡出、音质 songLevel（QualityLevel）、EQ 10 段 + preamp、响度归一化、限幅器、变速/变调默认 |
| 歌词 | 字号、对齐、翻译开关、滚动锚点 |
| 频谱 | enableSpectrum、spectrumBarWidth、spectrumDisplayMode(mirror/split) |
| 界面 | 主题（亮/暗/跟随系统）、封面动态取色、语言 |
| 窗口 | 窗口大小/位置记忆、最小化到托盘、启动恢复播放 |
| 下载 | 默认目录、并发数 |
| 平台 | 各平台登录态、首选音质 |

- Flutter 经 `/api/config/*` 读写；schema 变更走 server 既有 `config/migrations.ts` 迁移

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
| Streaming（Emby/Jellyfin/Subsonic）| 复用侧车 streaming 路由 | Phase 3+ 可选 |
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
│   │   │   ├── sidecar/        # 侧车桥接（rpc_client / sidecar_process）
│   │   │   ├── playback/       # 播放层（2026-08-06）：audio_engine_process / ogg_stream_bridge / pcm_analyzer
│   │   │   │                   #   / fft_bindings / fft_frame / media_renderer / playback_notifier / engine_paths
│   │   │   └── state/          # providers（DI）
│   │   ├── services/           # PlaybackController / LyricSync / ApiService / Session / Storage
│   │   ├── features/           # search / playlist / player / settings / login / library / lyric-window
│   │   └── ui/                 # 页面、组件、主题、i18n
│   ├── linux/ windows/ macos/  # 平台壳（含侧车 spawn + 资源定位）
│   └── pubspec.yaml
├── audio-engine/               # C 音频引擎（纯原生库：src/ include/ CMakeLists.txt；build/ 产物 archoera-audio-engine、libfft.so）
├── sidecar/                    # Node 侧车（= server/ 同构：services/player.ts Web 兼容 + audio-engine/binding.ts 归位 + 子进程引用 + 测试）
├── native/                     # Rust：media-ctrl / taskbar-lyric（napi，Phase 3+）；tempo-rs 随 C 引擎仓库
├── tools/                      # 原生二进制三平台构建脚本、node 运行时下载、同步脚本
├── KuGouMusicApi/              # 上游克隆（更新为最新 main，保留第三方声明）
├── THIRD-PARTY-NOTICES.md      # 三方依赖声明（MIT/AGPL 合规）
└── docs/
```

---

## 12. 实施路线（细化）

| 阶段 | 内容 | 出口标准 |
|---|---|---|
| **Phase 0** 骨架 ✅ | `flutter create`（linux/windows/macos）；复制 `server/` → `sidecar/` 并打通 esbuild 打包；构建 `archoera-audio-engine`；Flutter spawn 侧车 + health 探测 + 优雅退出；HTTP/WS 打通 | **已完成（2026-08-05，见 §12.0）**：`flutter run` 起 App，侧车在线，`/api/health` 200，`/api/audio/status` 引擎可用，看门狗防孤儿 |
| **Phase 1** Netease + 播放 | **桥接改造（§9）✅**：控制面 stdio JSON-RPC（复用 Hono `app.request()`，事件走 stdout）；**桌面直连引擎播放（§5.1/§12.0.3）✅**：Flutter spawn 引擎三路 UDS → 完整转码落盘 → libmpv 播放本地文件，seek 本地跳转，FFT 拉模式；侧车 `services/player.ts` 保留 Web 兼容（§12.0.2）；Flutter：搜索页、播放页（歌词 + 频谱）、二维码登录、队列；歌词走 `/api/lyric`（含 resolve 标准化，§10.2） | 可登录、搜索、播放网易云歌曲，歌词/频谱同步，可 seek（本地瞬时、时长完整），控制面无端口 |
| **Phase 2** KuGou | 更新 KuGouMusicApi 克隆 → 提取核心 → 移植 kugou 模块（song_url/榜单/歌单）进 sidecar；Flutter 接入酷狗搜索播放 | 可搜索播放酷狗歌曲 |
| **Phase 3** 补全 | QQ 音乐接入；本地曲库（C# scanner + 音乐库页 + watcher）；本地播放走统一 Opus 转码（§5.4）；下载（Rust CLI）；桌面歌词窗口；媒体键/托盘（media-ctrl napi）；C 引擎进程内 seek（可选）| 核心功能对齐 SPlayer-Next 子集 |
| **Phase 4** 优化 | C 引擎增强：进程内 seek、预加载/无缝切换、带宽降级策略（§5.4）、**FLAC/raw PCM 直通输出模式（本地 bit-perfect，可选）**；性能/内存基线（沿用原项目 memory discipline）；缓存与并发策略 | 播放体验优化，桌面集成完备 |

### 12.0 Phase 0 落地说明（已完成）

**产物**
- `app/`：Flutter 应用（linux/windows/macos 平台壳），`lib/main.dart` 引导页 + `lib/core/sidecar/sidecar_process.dart` 桥接
- `sidecar/`：`server/` 的完整副本（rsync，排除 node_modules/dist/bin 产物），`shared/` 同级副本 → **build.mjs 与 tsconfig paths 零改动**；`node build.mjs` 产出 `dist/index.js`
- `sidecar/audio-engine/build/archoera-audio-engine`：C 引擎（FFmpeg + Rust tempo 静态链接）按 devPath 约定落位

**桥接关键点（sidecar_process.dart）**
- 随机空闲端口：`bind(0)` 取号后释放（自用竞争可接受）
- 自包含数据根：`SPLAYER_DATA_DIR` → `~/.local/share/ArchoeraMusic`
- **stdin 看门狗**：Flutter 以管道模式 spawn；宿主进程死亡（含 kill -9）→ 管道关闭 → sidecar `stdin 'end'` 自退出（[index.ts](file:///home/betastudio2/文档/SPlayer-Next/ArchoeraMusic/sidecar/index.ts) 末尾，`SPLAYER_PARENT_WATCHDOG=true` 启用，不影响上游行为）
- 环境覆盖：`ARCHOERA_SIDECAR` / `ARCHOERA_DATA_DIR`（打包阶段替换路径用）

**验证记录**：`/api/health` 200；`/api/audio/status` `{available:true, format:"ogg/opus"}`；C 引擎 tone.wav→OGG 转码成功（`OggS` 魔数）；kill -9 硬杀应用后侧车自退出无孤儿。

### 12.0.1 Phase 1 首步：桥接改造落地说明（已完成，2026-08-05）

**产物**
- `sidecar/rpc.ts`：RPC 适配器（`SPLAYER_RPC=true` 门控）。stdin 读 JSON-RPC 请求 → **复用 Hono `app.request()` 映射全部既有路由（路由零改动）**；JSON 响应 → `data`，非 JSON（文件/转码流）→ cancel body 并返回媒体口 URL（`stream:true`）；`PING` 替代 `/api/health`；订阅 `utils/events` 事件总线 → stdout 事件行（含初始快照，对齐 WS 行为）；模块加载即把 `console.log/debug` 重定向 stderr，stdout 只留协议行
- `app/lib/core/sidecar/rpc_client.dart`：Dart RPC 客户端——stdin 写请求 / stdout 解析响应与事件；`call()` 统一错误模型 `ApiException(code, message)`；幂等 GET 指数退避重试（≤3）；`StreamUrlResult` 承载媒体口 URL；`Stream<SidecarEvent> events`（`scan:*`/`audio:fft`/`download:*`）
- `app/lib/core/sidecar/sidecar_process.dart`：spawn 时加 `SPLAYER_RPC=true`；就绪检测由 HTTP 健康轮询 → **RPC ping**；暴露 `rpc`；`stop()`/退出时 `rpc.close()`
- `sidecar/utils/events.ts`：`ServerEvent` 增加 `audio:fft`（桌面端经 stdout 透传，§10.1）；`routes/audio.ts` FFT 回调同时 `emit()`（保留 WS 广播，Web 兼容）
- `sidecar/index.ts`：SIGTERM handler 修复——`shutdown()` 后 `process.exit(0)`（原只清理不退出，导致 SIGTERM 杀不掉）

**协议**（单行 JSON，`\n` 分隔）
- 请求：`{"id":1,"method":"GET","path":"/api/...","body":{...}}`
- 响应：`{"id":1,"ok":true,"status":200,"data":{...}}` / `{"id":1,"ok":false,"status":404,"error":"..."}`
- 流响应：`{"id":1,"ok":true,"status":200,"stream":true,"url":"http://127.0.0.1:{port}/...","contentType":"..."}`
- 事件：`{"event":{"type":"audio:fft","data":{...}}}`

**验证记录**
- 管道测试：PING / `GET /api/health` / `GET /api/audio/status` / 404 路由 / POST body 透传 / SPA 静态页 `stream:true` URL——全部符合协议
- stdout 纯协议行（路由模块顶层日志已随 rpc import 前置重定向至 stderr）
- `flutter build linux --debug` 通过；编译产物运行 → `[app] sidecar ready: 控制面 RPC / 媒体口 http://127.0.0.1:44897`（RPC ping 就绪）
- SIGTERM 应用后无孤儿（onDetach + stdin 看门狗双保险）

### 12.0.2 Phase 1 次步：侧车播放服务 + media_kit 播放（已完成，2026-08-05；**桌面端已由 §12.0.3 直连引擎取代，本节保留为 Web 兼容路径记录**）

**产物**
- `sidecar/services/player.ts`：播放服务单例——`load(source, options)` spawn 交互式 C 引擎（`--interactive`，效果配置继承）；`seek(offsetMs)` **重启引擎 + `--offset`**（流 URL 固定，Flutter 重新 open 即拉到新引擎流，§5.3）；`stop()` 优雅 SIGTERM；`control(cmd)` 转发（set_eq/set_volume/set_*）；事件经 events 总线 → RPC stdout：`player:state`（playing/source/offsetMs）、`player:done`（仅自然退出/播放结束，主动 stop/seek 替换不触发——按引擎实例 isCurrent 判定）、`player:error`、`audio:fft`（streamId=会话 id）
- `sidecar/routes/player.ts`：`GET /api/player/stream`（当前引擎 stdout chunked OGG，客户端断开引擎保持）+ `POST /load` `/stop` `/seek` `/control` + `GET /status`
- `sidecar/utils/events.ts`：`ServerEvent` 增加 `player:state` / `player:done` / `player:error`
- `app/lib/core/playback/media_renderer.dart`：libmpv 纯音频封装（`media_kit` Player）——open/play/pause/stop/seek/setVolume + position/duration/playing/completed/error 流
- `app/lib/main.dart`：`MediaKit.ensureInitialized()` + **`_fixNumericLocale()`**（`setlocale(LC_NUMERIC,"C")` via dart:ffi）+ 播放测试面板（源输入 / 加载播放 / 暂停 / +10s / 停止 / 健康检查 / 日志区）

**关键坑（media_kit/libmpv，Linux）**
- **非 C locale 下 libmpv 段错误**（SIGSEGV，启动即崩）——mpv 官方要求 `setlocale(LC_NUMERIC, "C")`，必须在 MediaKit 初始化前调用；用 `DynamicLibrary.process().lookup<NativeFunction>` + `asFunction`（Dart 3.12 下 `lookupFunction` 泛型约束不可用）
- 系统已装 libmpv（/usr/lib/libmpv.so.2）→ media_kit 直接复用，无需 `media_kit_libs_linux`（省 ~50MB）

**验证记录**
- Node 侧：load → `playing:true` + sessionId；stream 200 `audio/ogg` + `OggS` 魔数；seek → 新引擎 `--offset 2000ms` + 新流 OggS；自然退出 → `player:done`；stop → `playing:false`
- Flutter 端到端：`flutter build linux --debug` 通过；GUI 实测——点击「加载播放」→ RPC load → C 引擎转码 `/tmp/test-tone.wav` → media_kit 拉媒体口流 → 播放 → `转码完成`（code=0）→ `player:done`；SIGTERM 无孤儿

### 12.0.3 桌面端直连 C 引擎（已完成，2026-08-06）

**背景**：旧链路「Flutter → 侧车播放服务 → binding → stdout OGG 流式 HTTP」存在两个体验问题——(1) 流式转码下前端拿到的是实时增长时长，对齐原项目「完整时长 + 任意 seek」语义失败；(2) 每次 seek 重启引擎重转码。改为 Flutter 直连引擎三路 UDS + **全速完整转码落盘 + libmpv 播放本地完整文件**。

**产物（app/lib/core/playback/）**
- `audio_engine_process.dart`：spawn + stdin JSON 命令 + 三路 UDS 连接；`EngineEvent`（ready/status/done/error/exited）；done Completer（转码完成 = 文件就绪）；stop = SIGTERM→SIGKILL + 删会话目录；sessionId = socket 目录名
- `ogg_stream_bridge.dart`（OggFileSink）：stream.uds → `stream.ogg` 落盘（IOSink 非 `StreamConsumer<Uint8List>`，手动 listen，不可 pipe）
- `pcm_analyzer.dart`（PcmAnalyzer）：pcm.uds → `stream.pcm` 落盘 + (posMs→fileOffset) 索引；`frameAt(pos)` 按需读帧
- `fft_bindings.dart`（FftAnalyzer）：FFI libfft.so；`fft_set_enabled(1)` 显式；输入缓冲 fftSize×32（修复 6144 越界段错误）
- `engine_paths.dart`：`ARCHOERA_AUDIO_ENGINE` → `resolvedExecutable` 祖先链找 `audio-engine` → cwd 兜底
- `media_renderer.dart`：libmpv 播放本地完整 OGG；`seek()` 本地 seek
- `playback_notifier.dart`：组合引擎+渲染器；ready 回填完整时长；done → open 文件；FFT 拉模式 50ms 轮询

**C 引擎（audio-engine/src/main.c）**
- 三路 UDS：`--stream-uds`（等待消费者 15s 保证 OGG 从头完整）/ `--pcm-uds` / `--control-uds`（替代 fd3，Dart 无法传额外 fd）
- `control_send_line()`：control.uds 优先，否则 fd3（Web 兼容）；`signal(SIGPIPE, SIG_IGN)` 在 UDS 创建前全局设置
- 转码完成 done 后 keep-alive 超时自退出（code=0）

**sidecar**：binding.ts 归位 `sidecar/audio-engine/binding.ts`（修复 `@main/audio-engine/binding` 断裂，`node build.mjs` 可通过）；`services/player.ts` 保留为 Web 兼容，桌面端不再调用

**验证（AUTOPLAY）**：完整时长恒定 344426ms（非实时增长）；连续 seek 78034/21267/92148/150680ms 即时跳转、无重转码；FFT 频谱启动（本地 4038 块拉模式）；引擎转码完成 code=0；无段错误

### 12.1 构建、打包与分发（自用）

| 环节 | 做法 |
|---|---|
| 侧车构建 | 沿用 `server/build.mjs`（esbuild ESM 单入口），`dist/` 随包分发 |
| 原生二进制 | `audio-engine/build/`（archoera-audio-engine + libfft.so）+ `tools/` 三平台构建脚本；Linux/macOS 复用 server Docker 构建链；Windows 用 vcpkg/预编译 FFmpeg 库 |
| Node 运行时 | 官方 Node 压缩包按平台裁剪进 `resources/`（Phase 1）；后续评估 SEA 单文件 |
| Flutter 构建 | `flutter build linux/windows/macos`；平台壳（linux/windows/macos/ 壳目录）负责定位 `resources/` 并 spawn 侧车 |
| 产物结构 | `ArchoeraMusic + resources/{node, sidecar/dist, bin/*, lib/*}`（原生依赖按平台裁剪） |
| 分发 | Linux AppImage/tar；Windows zip（无签名 → SmartScreen 提示，自用接受）；macOS 未签名（Gatekeeper 右键打开；必要时 ad-hoc 签名） |
| 版本同步 | 与 SPlayer-Next `server/` 定期 diff 合并（§4.1），记录同步清单 |

### 12.2 测试策略

| 层 | 方式 |
|---|---|
| 侧车（Node）| `node:test`：apis 模块（mock 网络）、歌词管道（KRC/QRC/TTML **黄金文件**）、db 代理、config 迁移 |
| 引擎 | 沿用 `server/audio-engine/tests/`（test_fft 等）三平台构建冒烟 |
| Dart | 单元：api_client / ws_client / 队列模型 / 状态机；Widget：页面与歌词/频谱组件 |
| 集成冒烟 | 起侧车 → `/api/health` → netease 搜索/歌词 → **桌面端直连引擎**（AUTOPLAY：三路 UDS → 转码落盘 → libmpv 播放 → FFT 拉模式）；Web 兼容路径：C 引擎 `status` + `stream` → WS 事件 |
| 手动回归 | 播放/seek/切歌/登录/下载核心路径清单（自用场景） |

---

## 13. 风险与决策点

| 风险/决策 | 说明 | 对策 |
|---|---|---|
| server/ 同步成本 | 两仓库并行，server 持续演进 | 固定同步节奏 + diff 清单；sidecar 保持同构减少冲突 |
| Node 运行时体积 | 三平台各 ~30-60MB + 原生二进制 | 官方 node 起步，评估 SEA；子进程二进制按平台裁剪 |
| libmpv/media_kit 体积与依赖 | 三平台各 +20~50MB；需随包分发 FFmpeg 相关库 | media_kit 官方打包方案；体积自用可接受 |
| **Opus 重编码音质** | 统一转码对本地无损源为播放路径有损重编码 | 库文件保持无损；播放 ≥192kbps 透明；FLAC 直通模式（可选）支持 bit-perfect 本地回放 |
| **Seek 体验** | ~~重启引擎 seek 毛刺~~（桌面端已改 libmpv 本地 seek，无毛刺，2026-08-06）；Web 兼容路径仍为重启引擎 | Web 兼容路径保留 `--offset`；进程内 seek 为 Phase 3+ 可选优化 |
| 源下载抖动 | 在线播放依赖源下载速率 | 带宽降级策略（§5.4）：自动降级输出 bitrate 保平滑 |
| C 引擎依赖 | 三平台需 FFmpeg/libopus 库（Windows 打包复杂）| Docker 构建链已有；Windows 用 vcpkg/预编译库 |
| Flutter 多窗口成熟度 | 桌面歌词窗依赖第三方方案 | Phase 1 单窗口；预留多窗口抽象 |
| KuGou token/平台差异 | 完整版 vs lite 版不通用 | 选定一版，modules 内封装隔离 |
| 本机服务安全 | 随机端口仍可被探测 | 启动 token 校验（可开关）|
| 自动换源 | 跨平台搜索匹配可能命中不同版本 | 自用增强可关；优先展示当前平台结果 |
| 登录态失效 | 播放中断，需重登 | sessions 持久化 + `player:sourceError` 提示重登 |
| 受限音质 | 会员/版权受限时仅 128k | 正常播放 + 来源标记显示，不自动跳转 |
| **Web UI 重写** | 38 个 S* 组件 + AMLL 歌词引擎 + 14 类设置页需 Dart 重写 | 信息架构复用 + 首期裁剪（§10.7）；歌词解析移侧车，歌词引擎为重点工程 |
| 开源合规 | AGPL-3.0 + 三方 MIT 依赖 | THIRD-PARTY-NOTICES 维护；开源时声明来源 |

---

## 附：已确认决策记录

1. API 层承载：**Node 侧车**（= 复用 server/ 方案，非重写）
2. **音频主引擎：C `archoera-audio-engine`（统一转码管线）**——桌面与 Web 共用；Flutter 用 libmpv 播放 OGG/Opus 流；Rust `native/audio-engine` 不引入
3. KuGou 集成：**更新克隆 → 提取核心 → 移植进模块架构**
4. 目标平台：**桌面为主**（Windows / macOS / Linux）
5. 首期范围：**Netease + KuGou 在线音乐**
6. 媒体渲染端：**media_kit（libmpv）**
7. SQLite 写入一律经 `/api/db/*` 代理（沿用 server 规范）
8. C 引擎待补能力：`seek`（重启引擎方案先行，进程内 seek 为 Phase 3+ 优化）；本地默认统一 Opus 转码，**保留 FLAC/raw PCM 直通输出模式**（可选，本地 bit-perfect 用；FFT 不受输出格式影响）
9. 带宽策略：转码输出走回环不占外网；源下载速率不足时自动降级输出 bitrate 保平滑
10. 队列 / 播放历史 / UI 偏好存 **Dart 本地**（drift/Hive）；业务数据（曲库/统计/会话）单一事实源在侧车
11. 歌词流水线复用 server：多源回退 + 匹配缓存（lyricMatchCache）+ TTML 标准化（含翻译，lyricTtmlCache）
12. 播放容错：源失效 → 可选自动换源（跨平台搜索匹配，自用增强可关）；受限音质正常播 + 来源标记
13. 桌面配置并入侧车 `config/store`（desktop 分组），Flutter 经 `/api/config/*` 读写，迁移走 `config/migrations.ts`
14. UI 策略：信息架构/交互保留，组件 Flutter 原生重写；**AMLL 歌词引擎 Dart 移植**；Web 端歌词解析（`parse*.ts` + `resolve.ts`）整体移入 sidecar 标准化，Flutter 零解析负担
15. 歌词多源回退由**前端编排**（设置 `lyricSourceOrder`/`lyricFormatOrder`/`smartPreferOnline`），侧车只提供各平台 match/ttml 端点
16. **核心处理逻辑必要时可用 C/C++**：Node GC 较差（长驻进程老生代/STW 停顿/对象碎片化）+ 性能瓶颈/算法密集时允许下沉原生（子进程 CLI 或 FFI）；下沉需 **profile 证据驱动**，默认复用优先，不主动重写
17. **桌面端零 TCP 端口（§9，2026-08-06 更新）**：控制面走 stdin/stdout JSON-RPC（RPC 适配器复用 Hono `app.request()`，路由零改动，事件走 stdout）；媒体面由引擎三路 UDS 承载（完整转码落盘 → libmpv 播放本地文件，**不再需要 loopback 媒体口**）；server 默认绑 `127.0.0.1`（原默认 `::` 局域网暴露已修）；WS 桌面端停用、保留 Web 兼容路径
18. Flutter 原生能力直接用：i18n 走 `flutter_localizations` + `intl`/`gen_l10n`（ARB，非自研）；Dart 侧 `EventBus` 作为应用层统一事件通道（侧车事件 + 本地事件），UI 不直连传输层
19. **桌面端直连 C 引擎（2026-08-06）**：Flutter spawn 引擎三路 UDS（stream/pcm/control），**全速完整转码落盘 → libmpv 播放本地完整 OGG**——恢复原 SPlayer-Next「完整时长 + 任意 seek」语义；seek 走 libmpv 本地 seek（不重启引擎、不重转码）；FFT 为拉模式（按播放位置从本地 PCM 索引读帧 + FFI libfft.so）；侧车播放服务保留 Web 兼容路径
20. **sidecar 播放路径收窄**：binding.ts 归位 `sidecar/audio-engine/`（随 sidecar 构建，`@main/audio-engine/binding` 可解析）；sidecar 后期可能更换方案（暂不深入优化）
