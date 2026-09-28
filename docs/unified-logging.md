# 统一日志（Unified Logging）

全层（Dart / 平台桥接 C++ / C 引擎 / Rust 下载器 / Zig 内核）日志的统一格式、
分级着色、落盘与注入契约。实现依据：`app/native/log/`（核心）、各模块的
`*_set_log_sink` 注入点。

## 1. 格式规范

```
[HH:mm:ss INFO] initialize
[HH:mm:ss WARN] [resolver] could not resolve song xxx.mp3:invalid tag
[HH:mm:ss ERROR] 429 too many requests
[HH:mm:ss FATAL] [kernel] Kernel Decode Error
```

- 时间戳：本地时间 `HH:mm:ss`（24 小时零填充）。
- 级别记号：`DEBUG` / `INFO` / `WARN` / `ERROR` / `FATAL`。
- 模块标签：可选。提供时以 `[tag] ` 形式紧跟在级别记号之后（如
  `[12:00:00 WARN] [resolver] ...`）；省略标签时与上例完全一致。
- **仅级别记号着色**，不染整行；落盘文件为不含 ANSI 的纯文本。

### 级别与颜色

| 级别 | 数值 | 控制台颜色 | 语义 |
| --- | --- | --- | --- |
| DEBUG | 0 | 灰 `\x1b[90m` | 诊断细节（默认过滤） |
| INFO | 1 | 绿 `\x1b[32m` | 生命周期 / 状态 |
| WARN | 2 | 黄 `\x1b[33m` | 可恢复 / 降级 |
| ERROR | 3 | 红 `\x1b[31m` | 失败路径 |
| FATAL | 4 | 加粗亮红 `\x1b[1;91m` | 致命 |

着色仅在 stderr 为终端时启用（Windows 自动开启 VT 转义）；可用
`archoera_log_set_color()` / Dart `Log.setColor()` 强制开/关。

## 2. 输出目标

- **控制台**：stderr，带色、即时 flush。
- **落盘**：`<dataDir>/logs/archoera.log`（`dataDir` 见 `stores/data_dir.dart`：
  Linux `~/.local/share/ArchoeraMusic`、macOS `~/Library/Application Support/ArchoeraMusic`、
  Windows `%LOCALAPPDATA%\ArchoeraMusic`；可用 `ARCHOERA_DATA_DIR` 覆盖）。
- **大小上限**：**单文件、硬上限 4 MiB**（`archoera_log_set_max_bytes` 可调）。
  达到上限时**原地截断重写**（写入一条截断标记），**不生成 `.1/.2/.3` 等兄弟文件**，
  磁盘占用恒为「一个文件」。可用 `archoera_log_set_file_enabled(0)` / Dart
  `Log.setFileEnabled(false)` 完全关闭落盘（仅控制台）；设置页「缓存」分类有
  对应开关（偏好 `app.logToFile`，默认开）。

### 内存安全（关键设计）

日志核心**不做内存队列/缓冲驻留**：每次调用在栈上格式化为单行（上限 3 KiB），
立即写 stderr + 文件后即丢弃。文件句柄与大小状态为固定大小静态数据。因此
长时间运行不会因日志累积而泄漏，也不存在「后台写线程队列无界增长」问题。
Dart 侧仅在传输当次分配并立即释放 UTF-8 缓冲，不保留任何日志副本。

## 3. 架构与注入

```
        ┌─────────────────────────── libarchoera_log（进程内唯一 sink）──────────────────────────┐
Dart ──▶ archoera_log_write ──▶ [HH:mm:ss LEVEL] [tag] msg ──▶ stderr(色) + logs/archoera.log
        └───────────────────────────────────────────────────────────────────────────────────────┘
             ▲                  ▲                     ▲                    ▲
   Log.nativeWritePointer  apl_set_log_sink  archoera_mediaengine_  archoera_downloader_
   （host 注入源）          （平台桥接）       set_log_sink（C 引擎）  set_log_sink（Rust）
                                                                      └→ zk_set_log_sink（Zig 内核）
```

- Dart 在 `main()` 最先调用 `Log.init(dir: <dataDir>/logs)` 载入核心库并配置。
- 其余原生模块加载后由 Dart 调用其 `*_set_log_sink(ptr, minLevel)` 注入
  `archoera_log_write` 指针；未注入时各模块回退 stderr（不静默丢失）。
- 该模型避免跨语言重复实现格式化/落盘，也避免 native→Dart 回调队列。
- **FFmpeg 内部日志**（`av_log`）不再直写 stderr：引擎在 `decoder_log_callback`
  中按 `AV_LOG_*` 映射到统一级别，并以 `[ffmpeg]` 标签并入 sink
  （如 `[HH:mm:ss ERROR] [ffmpeg] [https @ 0x…] HTTP error 429 Too Many Requests`）。
- **跨 isolate**：原生模块可能在 `Isolate.run(...)` 的临时 isolate 中加载
  （如引擎 create 在后台 isolate）。`Log` 的静态状态不跨 isolate，故
  `Log.nativeWritePointer` 会在本 isolate **懒打开核心库**取得同一进程的
  `archoera_log_write` 指针；核心的目录/级别/着色是进程级状态，主 isolate
  `Log.init` 后全局生效，因此子 isolate 注入的 sink 同样写入同一日志文件。

### 各层入口

| 层 | 注入 API | 调用方式 |
| --- | --- | --- |
| 平台桥接 C++ | `apl_set_log_sink` | 内部 `archoera::log(level, tag, msg)` |
| C 音频引擎 | `archoera_mediaengine_set_log_sink` | `ERA_LOGI/W/E/...`（`src/era_log.h`） |
| C++ 刮削器 | `archoera_scraper_set_log_sink` | `SCRAPER_LOGI/W/E/...`（`include/scraper_log.h`） |
| C# 扫描器 | `scanner_set_log_sink` | `Log.Info/Warn/Error` → 统一 helper（UTF-8 → sink） |
| Go Subsonic | `archoera_subsonic_set_log_sink` | `logInfo/Warn/Error` → cgo `C.sub_log_emit` |
| Rust 下载器 | `archoera_downloader_set_log_sink` | `log::info!/warn!/...`（自定义 `log::Log`） |
| Rust 转码器 | `archoera_transcoder_set_log_sink` | Go 侧 dlopen 后转发同一 sink |
| Zig 内核 | `zk_set_log_sink`（引擎转发） | `kernel/log.zig` 的 `emit()` |
| Dart | `Log.i/w/e/f/at(tag, msg)` | 直接调用 |
| vault 子进程 | （跨进程无法共享 sink） | Dart 转发其 stderr：`Log.at(…)`，按关键字分级 |

## 4. 在代码里加日志

- **Dart**：`import '.../services/log/log.dart';` → `Log.w('downloader', '降级：$e')`。
  级别按语义选择；不要再用裸 `debugPrint`（`debugPrint` 已统一收口到 INFO）。
- **C 引擎**：`#include "era_log.h"` → `ERA_LOGE(NULL, "%s 打开失败: %d", LOG_TAG, rc)`。
- **C++ 刮削器**：`#include "scraper_log.h"` → `SCRAPER_LOGE(NULL, "[scraper] …")`。
- **C# 扫描器**：用 `Log.Info/Log.Warn/Log.Error("scanner", "…")`（勿直接 `Console.Error`）。
- **Go Subsonic**：用 `logInfo/logWarn/logError("subsonic", "…")`（勿直接 `log.*`）。
- **Rust**：沿用 `log::warn!` 等宏（下载器）或 sink 助手（转码器）。
- **C++ 桥接**：`archoera::log(2 /*WARN*/, "platform", msg)`。
- **Zig 内核**：`era_log.emit(2, "kernel:runtime", "…", .{})`。

## 5. 构建与打包

- 核心库产物：Linux `libarchoera_log.so`、macOS `libarchoera_log.dylib`、
  Windows `archoera_log.dll`，统一落 `app/native/log/build/out/` 并安装到
  bundle 的 `native/`（与其它 FFI 库平铺，`NativeLibPaths` 祖先链查找）。
- 各平台顶层 CMake 与 `app/core/build-*.{sh,bat}` 已加入 `archoera_log` 构建；
  macOS 由 Xcode 拷贝阶段镜像进 `.app/Contents/MacOS/native/`。

## 6. 环境变量

- `ARCHOERA_LOG_LEVEL`：`debug|info|warn|error|fatal`（默认 `info`）。
- `ARCHOERA_LOG_LIB`：覆盖核心库路径（调试用）。
- `ARCHOERA_DATA_DIR`：数据根目录，进而决定 `logs/` 位置。
