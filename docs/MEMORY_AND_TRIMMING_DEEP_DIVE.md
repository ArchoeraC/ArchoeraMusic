# 运行时内存治理与剪裁路径规划（Memory & Trimming for ArchoeraMusic）

> 状态：**规划稿 v1 · 2026-08-18**
> 定位：把 Mineradio「四层作战面」的内存框架，按本项目（Flutter/Dart + FFI 直连 C/Zig
>       原生引擎）的实际栈重新映射，形成一条**可落地、可度量、有边界**的运行时内存优化路径。
> 依据：[architecture.md](./architecture.md) §5/§10、[audio-kernel-zig.md](./audio-kernel-zig.md)、
>       [module-on-demand-load-plan.md](./module-on-demand-load-plan.md)
>
> ⚠ **更正（2026-08-18，栈映射）**：Mineradio 是 Electron 多进程 + WebGL 渲染，其 L1
> （`EmptyWorkingSet` 工作集压缩）与 L2（`NtSetSystemInformation` 系统级 purge）依赖 Windows
> 特权原语与多进程边界。本项目桌面端为 **FFI 直连进程内引擎**（architecture.md §5.1），无子进程
> 可裁、也无权做系统级 purge——故原 L1/L2 在此改为等价的 **L1 Dart/UI 堆** 与
> **L2 原生引擎常驻缓冲** 两个作战面；L3 磁盘缓存与 L4 渲染/纹理预算可直接映射保留。

---

## 0. 一句话结论

Mineradio 把内存拆成「工作集压缩 / 系统 purge / 磁盘缓存 LRU / GPU 预算淘汰」四层，每层都配了
**能力检测、降级路径、硬预算、安全开关与结果度量**。本项目的「极限」应落在等价四层上：
**L1 把 Dart 堆里的大列表/大缓存做成有界 + 懒加载；L2 把原生引擎最大的单块（miniaudio 全曲
解码 WAV）从无界变为有界；L3 给磁盘缓存补上缺失的上限与清扫；L4 让渲染层纹理/模糊/频谱按
可见性与预算裁剪**——并把「每笔释放可度量」固化成调试面板。

---

## 1. 现状基线（2026-08-18 盘点）

> 口径：桌面端（Linux/Windows/macOS）运行态。量级为按代码常量与典型值的推算，待 §9 度量
> 面板实采校准。

| # | 消耗点 | 层 | 量级（典型） | 现状 |
|---|--------|----|--------------|------|
| 1 | 音乐库全量载入（`library_store.dart:141` `listTracks(limit:100000)`，`tracks_db.dart:124` `SELECT *` 含 `lyrics` 列） | L1 | 万级曲目 → 数百 MB Dart 堆 | ❌ 无界 |
| 2 | miniaudio 全曲解码 float32 WAV（`player.c:81-82` `MA_SOUND_FLAG_DECODE`；`mediaengine_lib.c:205` `byte_rate=sr*ch*4`） | L2 | 4min@44.1k≈85MB、@96k≈184MB | ❌ 无界 |
| 3 | 播放队列双拷贝 `queue` + `_originalQueue`（`playback_notifier.dart:761`、`:995`） | L1 | 队列 ×2 全量 Track 对象 | ⚠️ 冗余 |
| 4 | 双平台 liked 全量驻留（`liked_loader.dart:40`、`:194-202` 分页拉全量） | L1 | 千级 → 数 MB/平台 | ⚠️ 有界于账号规模 |
| 5 | ImageCache 纹理缓存（`app.dart:62-66`） | L4 | 默认 8 MiB / 1000 张 | ✅ 有界（`null` 哨兵 `1<<60` 例外） |
| 6 | 歌词/匹配/TTML 内存缓存（`app.dart:67-72` → `runtime.dart` 三 LRU） | L1 | 默认 1 MiB ≈ 700 首 | ✅ 有界 |
| 7 | SongCache 磁盘 LRU（`song_cache.dart:117`；`prefs_preset.dart:22` 默认 512 MiB） | L3 | 默认 512 MiB | ✅ 有界 |
| 8 | Netease API LRU 缓存（`apis/netease/core/cache.dart`） | L1 | 200 条、无字节预算 | ⚠️ 无字节上限 |
| 9 | 会话 scratch 目录 `stream.wav`/`stream.pcm`（`audio_engine_process.dart:172-174`、`mediaengine_lib.c:405-407`） | L3 | 磁盘与 WAV 同量级 | ✅ stop 时删除 |
| 10 | 封面磁盘缓存 `cache/covers`（scanner 直写） | L3 | 无上限 | ⚠️ 无界 |
| 11 | 全屏模糊/玻璃面（`shell.dart:127-136`、`glass_surface.dart` 等） | L4 | 全屏离屏纹理 | ⚠️ 前台常驻 |
| 12 | 封面色提取每曲全量重下（`cover_color.dart:37-42` `res.fold` 全字节再解码 64×64） | L1/L4 | 50–200 KB/曲、无缓存 | ⚠️ 无缓存 |

**核心结论**：项目已把「容易做的有界」做完了——图像解码降采样（§6）、磁盘/歌词缓存上限、
列表虚拟化（`SongList`/`LyricsView` 均为 builder）、FFT 按需读盘、事件降频——但**最大的两块
（音乐库全量、原生全曲解码）恰好是无界的**，这正是运行时内存偏高的主因；治理应从这两处起步。

---

## 2. 整体分层：四层「管理与剪裁」映射

| Mineradio 层 | ArchoeraMusic 等价层 | 对象 | 手段 | 关键文件 |
|--------------|----------------------|------|------|----------|
| L1 进程工作集压缩 | L1 Dart/UI 堆 | 曲库、队列、liked、API/歌词缓存 | 分页 + 懒加载 + 去冗余 + 字节预算 | `library_store.dart`、`playback_notifier.dart`、`runtime.dart` |
| L2 系统级内存 purge | L2 原生引擎常驻缓冲 | 引擎线程解码缓冲、FIFO、会话文件 | 输出有界化 + 生命周期显式释放 + 平台级 trim | `player.c`、`mediaengine_lib.c` |
| L3 磁盘缓存 LRU | L3 磁盘缓存 | SongCache、封面、sqlite、会话文件 | 容量上限 + LRU + 启动清扫 | `song_cache.dart`、`tracks_db.dart` |
| L4 GPU 显存预算池 | L4 渲染/纹理预算 | ImageCache 纹理、模糊、频谱 | 字节预算 + 解码降采样 + 可见性门控 | `app.dart`、`cover_image.dart`、`spectrum_view.dart` |

---

## 3. L1 Dart/UI 堆治理（应用侧）

### 3.1 音乐库全量驻留（当前最大头）

`library_store.dart:141` 一次载入 `listTracks(limit:100000)`，且 `tracks_db.dart:124` 用
`SELECT *` 把每行 `lyrics`（内嵌歌词文本）也拉进内存；`library_page.dart:115` 每次 build 又
`map(trackFromRow).toList()` 重建全量 `List<Track>`。

- **立即可做**：`listTracks` 列表查询改**显式列**（去 `lyrics`/大字段），歌词仅在播放/进歌词页时
  按 id 懒查。
- **中期**：`LibraryNotifier` 改**分页**（`limit:500`/页 + 滚动加载），搜索下推 SQL
  （`tracks_db.dart:121` 已有 `LIKE` 分支），废弃内存过滤 `filteredTracks`
  （`library_store.dart:53-62`）。
- **守则**：**数据拿全、UI 懒渲染/虚拟化**——分页只改「驻留形态」，不做「截断到 500 首」的
  假优化（对齐原版 LOW_SPEC 纪律）。列表侧已是 `ListView.builder`，主要是 store 层改造。

### 3.2 播放队列双拷贝

`playback_notifier.dart:761` `_originalQueue = List.of(tracks)` 与 `state.queue` 全量复制，
shuffle 又 `_shuffledWithCurrentFirst`（`:998`）再复制一遍，队列变更（`moveInQueue`/`insert`/
`remove`）也频繁 `List.of`。→ 短期去 shuffle 全量复制（`_originalQueue` 改存原序索引表）；
长期队列改存**轻量 TrackRef**（source/id/quality），详情按需 lazy。

### 3.3 liked/歌单全量拉取

`liked_loader.dart:194-202` 双平台全量分页拉取后常驻 `_platforms`。→ 改**按需分页**（首屏
300 条 + 滚动续拉），结果落地 `liked_cache.dart`（磁盘），避免重复全量网络拉取 + 常驻。

### 3.4 IndexedStack 全 tab 常驻

`search_page.dart:578`、`streaming_page.dart:220` 用 `IndexedStack` 让 4 个 tab 全部常驻树中
（大列表 + 网格封面 + 滚动位置同时存活）。→ 改**懒构建**（首次切到才 build，保 index 状态），
切走不销毁数据、封面纹理由 L4 预算兜底。

### 3.5 歌词/API 内存缓存

歌词三件套已有字节上限（`app.dart:67-72`，默认 1 MiB）✅。缺口在 Netease API LRU
（`apis/netease/core/cache.dart` 200 条、无字节预算，个别响应如 `playlist_detail n:100000`
很大）→ 加 `maxBytes` 预算 + 按条目大小淘汰。

---

## 4. L2 原生引擎常驻缓冲

### 4.1 miniaudio 全曲解码（单块最大）

`player.c:81-82` `MA_SOUND_FLAG_DECODE` 把 `stream.wav`（**float32、源采样率直通**，
`mediaengine_lib.c:205`）整段解码进原生堆：4min@44.1k≈85 MB，高解析翻倍。三条候选路径
（按风险从低到高）：

1. **降输出位深**：`wav_begin` 改 16-bit（`byte_rate = sr*ch*2`）——播放端听感无感知风险低，
   原生解码内存直接减半，改动最小。
2. **统一 48 kHz 输出**：`passthrough=false`（`engine_bindings.dart:210` 已有开关）为长曲/
   高解析兜底，牺牲源采样率换内存，做成用户可配。
3. **流式播放**：去掉 `MA_SOUND_FLAG_DECODE`，seek 变重解码——需保 `stream.wav` 做 seek
   定位，权衡最大，列为长期项。

### 4.2 会话 scratch 目录生命周期

转码产物落 `Directory.systemTemp/archoera-*`（`audio_engine_process.dart:172-174`），
`stop()` 时删除 ✅。缺口：异常退出（崩溃/强杀）会残留 → **启动时清扫超龄（>24h）archoera-* 残留**。

### 4.3 有界缓冲盘点（已达标，保持）

事件 FIFO 512×512B / 命令 FIFO 256×4KB（≈1.3 MB，`mediaengine_lib.c:23-26`）、管线
`pcm_temp`/`tempo_buf` 按最大帧有界增长、FFT 数组常量级（`fft.c`）、Zig kernel `raw` 缓冲随
会话释放（`engine.zig:139-144`）——这些已是有界，本文不重复立项。

### 4.4 「系统级 purge」为何不适用

`NtSetSystemInformation` purge / `EmptyWorkingSet` 属 Windows 特权级系统操作，且依赖
Electron 多进程边界。本项目引擎在进程内（无子进程可裁）、无提权面（§7 权限纪律），等价做法是
把**常驻大缓冲消灭在源头**（§4.1）+ 进程内可控释放（Dart 侧 `imageCache.clear()` 等），
不为「跑分好看」引入系统级副作用。

---

## 5. L3 磁盘缓存治理

| 缓存 | 现状 | 治理 |
|------|------|------|
| SongCache（`<dataDir>/cache/song-cache`） | 512 MiB LRU ✅（store 后 `trim`，`playback_notifier.dart:551`） | 补：启动兜底 `trim`；目录可迁移 |
| 会话 scratch | stop 删除 ✅ | 补：启动清扫 >24h 残留（§4.2） |
| sqlite（library/history/liked） | history 500 cap ✅；liked 无 cap；WAL 未设上限 | 补：`journal_size_limit` + liked 行数上限/归档 |
| 封面 `cache/covers` | 无上限 | 设容量上限 + mtime LRU |

---

## 6. L4 渲染/纹理预算

- **图像解码降采样已达标** ✅：`cover_image.dart:58-84` `cacheWidth/cacheHeight` 按 dpr 钳到
  ≤2048；网格 320（`cover_grid.dart:283-287`）；背景图按屏解码钳 2560（`shell.dart:115-116`）。
- **ImageCache 预算** ✅：默认 8 MiB / 1000 张（`app.dart:62-66`）。风险点：用户设「无上限」时
  走 `1<<60` 哨兵（`app.dart:23`）仅剩张数约束——保留但不推荐，文档化。
- **模糊/玻璃面** ⚠️：全屏 `ImageFilter.blur`（`shell.dart:127-136`）+ 多处玻璃面
  （`glass_surface.dart`、`queue_panel.dart:360-361`）为前台离屏渲染常驻 → 后台/最小化/非播放
  时摘除模糊层（可复用事件降频协商 `engine-event-push-plan` 的档位信号）。
- **频谱绘制** ✅：`Ticker` 仅播放且可见时运行、`RepaintBoundary` 隔离（`spectrum_view.dart`）、
  取帧节流 100 ms / 节能 300 ms（`playback_notifier.dart:1293-1294`）——已是「隐藏即静默」。
- **封面色提取** ⚠️：`cover_color.dart:37-42` 每曲全量重下封面字节再解码 64×64 → 复用它处
  已解码缩略图（ImageCache 命中）或按 trackId 缓存提取结果。

---

## 7. 目标架构：能力检测 + 硬预算 + 度量闭环

对齐 Mineradio 的工程纪律（激进但可控）：

1. **所有激进路径都有开关与回退**：图像/歌词/缓存上限均已进设置（`prefs_preset.dart`）；
   新加的 L2 输出有界化（§4.1）应给「长曲降载」开关。
2. **前台不牺牲观感**：分页/懒加载不动 UI 数据完整性；模糊摘除仅限后台档位。
3. **每笔释放可度量**：建立调试面板（§9），ImageCache 字节、Dart RSS、引擎 WAV 尺寸、
   缓存目录占用（`song_cache.dart:149` `stats()` 已有）全部可见。
4. **权限边界**：不引入系统级 purge / 提权（对齐 Mineradio「默认不开自动释放、前台不弹 UAC」）。

---

## 8. 分阶段落地

### 阶段① 快速收益（低难度，无架构改动）

1. 列表查询去 `lyrics` 列 + `library_page.dart:115` memo 化（去掉最大字符串块）。
2. 队列 shuffle 去全量复制（`_originalQueue` 改存索引，`playback_notifier.dart`）。
3. Netease API 缓存加字节预算（`apis/netease/core/cache.dart`）。
4. 封面色提取结果缓存（`cover_color.dart`）。
5. 启动清扫 archoera-* 残留 + 封面磁盘缓存上限。

### 阶段② 重点突破（中难度）

6. 音乐库分页加载 + 搜索下推 SQL（`library_store.dart` / `tracks_db.dart`）。
7. L2 输出有界化：WAV 16-bit（§4.1.1）+ 长曲 48k 兜底开关（§4.1.2）。
8. liked 按需分页 + 落地缓存。
9. 模糊层后台档位摘除（`shell.dart`）。

### 阶段③ 长期优化（高难度）

10. 队列 TrackRef 轻量化（改动 state 模型，`playback_notifier.dart`）。
11. 引擎流式播放 + seek 权衡（§4.1.3）。
12. 内存度量面板 + 低内存自动降级（低 RSS 时自动收缩 ImageCache / 歌词缓存）。

---

## 9. 验证与度量

| 项 | 方法 | 目标 |
|----|------|------|
| Dart 堆 / RSS | 调试面板 `ProcessInfo.currentRss` | 万级曲库下较基线下降 ≥30% |
| 原生引擎 | 播放典型曲目采样 WAV 解码字节 | 16-bit 后减半 |
| ImageCache | `imageCache.currentSizeBytes / liveCount / pendingImages` | ≤ 设置预算 |
| 缓存目录 | `SongCache.stats()` 等 | ≤ 各上限 |
| 回归 | `flutter run --profile` + 长列表滚动 / 切歌 / 切 tab 冒烟 | 无卡顿、无 OOM |

---

## 10. 与既有计划的关系

- **module-on-demand-load-plan.md**：L2 原生模块的按需加载/释放（Tier 1/2）与本文 L2 缓冲治理
  互补——该文聚焦「库内模块生命周期」，本文聚焦「解码输出规模」。
- **robustness-improvement-plan.md**：会话残留清扫、异常释放与本文 L3 项重叠，落地时并入。
- **CROSS_PLATFORM_CAPABILITY_IMPROVEMENT.md**：其「跨平台能力抽象」视角与本文 L1–L4 分层一致，
  本文为其提供 Dart/桌面端侧的落地清单。

---

## 11. 风险与取舍

- **分页改动面大**：音乐库分页影响搜索/排序/选择联动，需守住「数据拿全、UI 懒渲染」纪律，
  不做截断式假优化（§3.1 守则）。
- **16-bit WAV 音质**：听感无感知风险低；高解析用户可保留直通（做成开关，§4.1.1）。
- **流式 seek**：去掉 `DECODE` 后 seek 延迟增大，务必保 `stream.wav` 定位或按需重解码，先 A/B。
- **懒 tab 丢状态**：IndexedStack → 懒构建需保滚动位置恢复，避免「切回刷新」体感劣化（§3.4）。

---

## 12. 一句话总结

本项目内存偏高源于**两块无界**（音乐库全量 + 原生全曲解码）叠加若干冗余/缺预算项；
照 Mineradio「四层 + 每层有界可度量」的框架，把 L1 列表/缓存做成分页 + 去冗余、L2 引擎输出
降到有界、L3 磁盘缓存补齐上限与清扫、L4 渲染按可见性裁剪，并配一个调试度量面板收口——
就能把运行时内存从「被动偏高」变成「预算内可控」。
