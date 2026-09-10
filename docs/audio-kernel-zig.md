# 独立音频内核设计（FFmpeg 默认主引擎 · C 壳保留 · Zig 渐进替换 · 跨平台优先）

> 状态：**设计稿 v3 · 2026-08-16**
> 定位：用 **Zig** 逐步重写 `app/core/audio-engine/` 的解码 / DSP 内核，得到一套**天然跨平台**、
> **自研优先**的独立音频引擎；**FFmpeg 保持为默认主解码引擎**（行为同现状，零回归），
> Zig 内核逐格式成熟后**按格式渐进接管**。只做**音频**，**不做任何视频解码**。
>
> **架构调整（2026-08-16，用户决策）**：
> - **FFmpeg 保持默认主引擎**：`-Duse-ffmpeg` 默认开启，FFmpeg 解码能力与现状完全一致，
>   发布版默认带 FFmpeg（LGPL-2.1+ 动态链接 + 合规说明，同现状）；用户/构建方始终可选 FFmpeg 为主；
> - **C 调用壳保留**：`mediaengine_lib.c`（FFI）/ `main.c`（CLI）/ `pipeline.c` / `player.c`
>   不作重写，`archoera_mediaengine.h` 符号面与 JSON 协议不变，Dart FFI 零改动；
> - **Zig 内核渐进替换**：每个格式的 Zig 实现经 bit-exact/对照验收后**按格式接管**（格式级
>   开关，如 `-Dzig-flac=true`）；未接管格式始终由 FFmpeg 提供；全部 T0/T1 验收后 Zig 可升为主
>   （`-Dzig-main=true`，可选），FFmpeg 仍保留为主引擎选项（§8.3）。
>
> **架构扩展（2026-09-08，用户决策，决策 #16）**：引擎引入**进程内模块化**（§8.4）——进程内一份
> "主控 Registry" 按格式分发任务，每格式**模块全局只读一份**、可开**任意多轻量实例**（实例 = 现有
> `decoder.Decoder`），目标支撑**高并发（128 路）**场景（HTTP 直连多路 / 批量 tag / 扫描响度 / 批量转码），
> 规避 FFmpeg 模型下"N 路 = N×(完整引擎上下文)"的资源爆炸。模块化只覆盖 **Zig 接管格式**；
> FFmpeg 兜底路径维持 per-context 不变（§8.3）。**A/Sync 执行与调度模型作为内核「二次增强」、
> 后置可选**（核心模块化不依赖），见 §8.4.1 / 决策 #17。
>
> 替代：`docs/audio-kernel-no-ffmpeg.md`（C11 方案，已废弃，保留作历史分析；其 FFmpeg 依赖点审计、
> 时长/seek、容错、测试护栏等结论仍适用，冲突处以本文为准）。
>
> 依据：AGPL-3.0 项目，任何引入的第三方必须为 Permissive（MIT / Apache-2.0 / BSD / ISC / OFL /
> MIT-0 / 公有领域）且与 AGPL 兼容（README「许可证」章节）。FFmpeg（LGPL-2.1+）以**动态链接 +
> RUNPATH=$ORIGIN 内嵌运行库**形式保留为**默认主引擎**（替换/重链权利见
> `app/core/audio-engine/THIRD-PARTY-LICENSES.md` 特别声明）。

---

## 目录

1. [设计原则](#1-设计原则)
2. [为什么用 Zig（跨平台论证）](#2-为什么用-zig跨平台论证)
3. [技术选型总览：依赖账本](#3-技术选型总览依赖账本)
4. [架构与模块](#4-架构与模块)
5. [构建系统：build.zig 与跨平台矩阵](#5-构建系统buildzig-与跨平台矩阵)
6. [输入与 IO 层](#6-输入与-io-层)
7. [格式探测](#7-格式探测)
8. [解码层设计](#8-解码层设计)
9. [各格式实现与依赖账本明细](#9-各格式实现与依赖账本明细)
10. [采样转换：格式转换 / 下混 / 重采样](#10-采样转换格式转换--下混--重采样)
11. [编码器与 OGG 封装（可选模块）](#11-编码器与-ogg-封装可选模块)
12. [时长 / 定位 / Seek 语义](#12-时长--定位--seek-语义)
13. [中断、错误与容错](#13-中断错误与容错)
14. [DSP 移植与 libfft.so（保持 Dart ABI）](#14-dsp-移植与-libfftso保持-dart-abi)
15. [播放器输出层（跨平台难点）](#15-播放器输出层跨平台难点)
16. [FFI 边界与 CLI](#16-ffi-边界与-cli)
17. [测试与验证](#17-测试与验证)
18. [构建与打包变更](#18-构建与打包变更)
19. [分阶段实施路线](#19-分阶段实施路线)
20. [风险与决策点](#20-风险与决策点)
21. [决策记录](#21-决策记录)

---

## 1. 设计原则

按优先级排序，后续所有技术选型都以此为准绳：

| # | 原则 | 含义 |
|---|---|---|
| **P1** | **跨平台优先** | 一套源码、三平台（Linux / Windows / macOS，含 x86_64 / aarch64）。单一构建系统（`build.zig`），尽量支持**从任一宿主交叉编译**；平台差异只出现在明确的边界层（音频输出、系统 SDK），其余全部平台无关 |
| **P2** | **自研优先（最小外部依赖）** | 内核核心（IO / 探测 / 解复用 / 采样转换 / DSP / 封装 / **播放输出层**）**全部自研 Zig**；只有"数学复杂度确实无法自研"的编解码器才引入外部实现，且必须是 **Permissive 单文件或可 vendored 源码**（源码入库，零二进制依赖、零构建期网络下载）。见 §3.3 裁决规则与 §3.7 最终裁决表 |
| **P3** | **FFmpeg 默认主引擎，Zig 渐进替换** | **默认构建启用 FFmpeg 解码**（`-Duse-ffmpeg` 默认开启，链接 `libav*` / `libsw*`，行为同现状零回归）；Zig 内核逐格式成熟并验收后**按格式接管**（格式级开关如 `-Dzig-flac=true`）；未接管格式始终由 FFmpeg 提供；全部 T0/T1 验收后 Zig 可升为主（`-Dzig-main=true`，可选），FFmpeg 仍保留为主引擎选项（§8.3） |
| **P4** | **纯音频、无视频** | 视频轨不处理、不支持、不探测；容器只解析音频轨 |
| **P5** | **行为兼容（迁移护栏）** | `archoera_mediaengine.h` FFI 导出符号、事件/命令 JSON 协议、`libfft.so` 的 Dart ABI、`stream.wav` / `stream.pcm` 落盘格式**全部不变**；Dart 侧仅新增"在线源预下载"一步（本条为**文件模式基线**的不变量；2026-09-08 起桌面播放默认改「内存播放（不落盘）模式」——新增能力不破坏本护栏，见 `docs/audio-memory-playback.md`） |
| **P6** | **格式广度（本地播放器兼容面）** | 作为本地播放器，应兼容尽可能多的音频类型（含 Hi-Res/无损收藏：FLAC/APE/WavPack/DSD/ALAC/AIFF 等）。通过**格式插件化**（comptime 特性开关）实现：默认构建只含核心格式保持轻量，需要时逐格式开启；每个格式模块独立实现/独立许可审查，互不拖累 |

> **P2 与 P6 的调和**：P2 约束"依赖形态"（必须 Permissive 单文件 / vendored 源码、源码入库、零构建期下载），
> 不约束"格式数量"；P6 决定"覆盖哪些格式"。两者结合即：**核心自研，扩展格式按需 vendored，全部可选编译**。
> 一个冷门格式许可证审查不通过，只禁用该格式开关，不影响其余。

---

## 2. 为什么用 Zig（跨平台论证）

| 维度 | 说明 |
|---|---|
| **交叉编译开箱即用** | Zig 自带完整工具链（zig cc / 自带链接器 / 各目标 libc + mingw 头），`zig build -Dtarget=...` 即可产出三平台产物，**不需要** Windows 的 MSVC / vcpkg / MinGW，也不需要 Linux/macOS 的 GCC / CMake 工具链——直接解决现状 `build_windows.bat` + `build-linux.sh` + `build-macos.sh` + 三套 CI 的碎片化 |
| **libc 可选（freestanding）** | 内核核心可**不链接 libc**（用 `std` 的 allocator/fs/thread/io），平台差异（malloc/printf/线程 API）彻底消失；CLI / 输出层需要时再 `linkLibC()` |
| **单一构建系统** | `build.zig` 声明式（target/optimize/CSource/install），替代 CMake + 各平台脚本；`zig build test` 内置测试运行器 |
| **可直接编译 C 单文件** | `addCSourceFiles` + `@cImport`，vendored 的单文件 C 库（如 stb_vorbis）零改造编译进内核，C 头 API 可直接 `@cImport` 调用 |
| **导出 C ABI / 可混合编译** | Zig 内核以 `export fn ... callconv(.C)` 导出 `zk_*` 桥接符号供 C 壳调用；`zig cc` 直接编译 C 壳源码（`addCSourceFiles`），`@cImport` 复用 C 头契约；Dart FFI（`engine_bindings.dart`）零改动 |
| **安全默认 + 性能** | 处理不可信媒体输入时，Zig 的边界/溢出检查（Debug/Safe 模式）+ ReleaseFast 高性能，天然比 C 稳 |
| **std 自足** | 自带 allocator、fs、thread/mutex/cond、哈希（含 CRC）、ArrayList 等，内核基础设施不再依赖任何三方库 |
| **一个语言贯穿内核** | 内核（解码 / 采样 / DSP / 容器 / 测试）全用 Zig 完成；C 壳仅保留 FFI/CLI 边界（2026-08-16 决策：调用部分留在 C），tempo-rs 仅作过渡兜底，自研 WSOLA 完成后移除（§9.6） |

> **为什么不选纯 C 重写**：现状 C 方案仍依赖 CMake + 三平台脚本 + FFmpeg/vcpkg 打包链，且"复用 miniaudio
> 内嵌 dr_*"意味着依赖 miniaudio 单头文件整体（含输出层），与 P2 冲突；Zig 能把"自研优先"贯彻到底。
> **为什么保留 C 壳**（2026-08-16 用户决策）：FFI/CLI 边界（`mediaengine_lib.c` / `main.c`）已稳定运行
> （含 Windows MSVC + `compat/pthread.h`），无需重写——Zig 只替代**内核**（解码 / DSP / 容器解析），
> 调用壳零风险、Dart 侧零改动。

### 2.1 FFmpeg 参考实现（已克隆，2026-08-16）

> **为"尽可能还原 FFmpeg 行为"克隆官方源码库作对照参考**（用户决策，2026-08-16）：
> 位于 **`ArchoeraMusic/reference/FFmpeg/`**（浅克隆 `n9.0.1` tag，与系统 FFmpeg 9 同源，
> 含全部 `libav*/libsw*` 的 **C 源码与头文件**；系统已装同版本 FFmpeg 运行库 + dev 头，可随时
> 编译对照）。用途：
> - **解码器参考**：`libavcodec/apedec.c` / `alac.c` / `wavpack.c` / `flacdec.c` /
>   `mpegaudiodec*.c` 等——Zig 自研无损解码器的逐位对照基准（§9、§17.2）；
>   MP3 另以 **minimp3**（CC0，`ArchoeraMusic/reference/mp3refs/minimp3/`）作标量路径逐位参考
>   （Layer I/II/III 全链 PCM 精确对照，§17.2；minimp3 仅参考、非编译依赖）；
> - **容器/帧格式**：`libavformat/*` 的封装细节（如 Ogg CRC、MP4 box、WavPack 块头）；
> - **行为还原**：`probe`、时长、seek、错误处理等与 FFmpeg 对齐（P5 行为兼容）；
> - **许可**：仅作**参考对照**，不拷贝代码进本仓库（AGPL/LGPL 隔离）；随库带入的 `libavcodec/version_major.h`
>   MAJOR 63 → FFmpeg 9（与系统 `libavcodec.so.63.1.101` / `pkg-config` 63.1.101 完全同源）。

---

## 3. 技术选型总览：依赖账本

### 3.1 一句话结论

> **解码 / DSP 内核以 Zig 自研为主**：IO / 探测 / 解复用 / 采样 / DSP / 封装 / 播放输出层自研 Zig；
> 编解码器自研（FLAC / APE / ALAC / WavPack / **MP3** / **AAC-LC**——均可用参考实现 bit-exact 校验，§3.7）；
> 仅"数学复杂度确实无法自研"的 Opus 引入 Permissive 实现；
> **C 壳（`mediaengine_lib.c` / `main.c` / `pipeline.c` / `player.c`）保留**为 FFI/CLI 边界；
> **FFmpeg 保持为默认主解码引擎**（`-Duse-ffmpeg` 默认开启，§8.3），Zig 内核逐格式验收后按格式接管。
> 全项目**默认构建**含 FFmpeg（LGPL-2.1+ 动态链接）一个"正式第三方库"，Zig 接管全部 T0/T1 后
> 可选 `-Dzig-main=true` 使 Zig 升为主（默认仍 FFmpeg）。

### 3.2 依赖账本

| 模块 | 形态 | 许可证 | 引入理由 / 自研成本 |
|---|---|---|---|
| WAV / AIFF / W64 / RF64 解复用 | **自研 Zig**（~250 行） | AGPL | RIFF 家族纯表结构，无数学复杂度 |
| OGG 解复用（页解析 / granule / CRC） | **自研 Zig**（~300 行） | AGPL | RFC 3533 简单；CRC-32 自写表（Ogg 用非反射多项式） |
| MP4 / M4A 音频轨解复用 | **自研 Zig**（~700 行） | AGPL | `ftyp/moov/mvhd/stbl/stco/stsc/stsz/stts` 表解析，无数学；视频轨直接跳过 |
| ADTS（AAC 裸流）解复用 | **自研 Zig**（~150 行） | AGPL | 帧头解析 |
| PCM 格式转换 / 下混 / 重采样 | **自研 Zig** | AGPL | 数学 + 表驱动，完全自研 |
| DSP：EQ / loudness / limiter / FFT | **自研 Zig**（移植现有 C，~1200 行） | AGPL | 现有 C 实现移植 + 增强 |
| OGG 封装（Opus muxer） | **自研 Zig**（~250 行） | AGPL | RFC 7845，页面/CRC/lacing |
| **FLAC 解码** | **自研 Zig**（~2500 行） | AGPL | 无损可 bit-exact 校验；dr_flac（MIT-0/PD）仅兜底 |
| **APE 解码** | **自研 Zig**（~1500 行，§9.10） | AGPL | 无损可 bit-exact 校验；参考 FFmpeg `apedec.c` |
| **ALAC 解码** | **自研 Zig**（已实现，~1800 行）；alac.c（Apache-2.0）兜底 | AGPL | 无损可 bit-exact 校验；Apple 参考 alac.c 作对照 |
| **WavPack 解码** | **自研 Zig**（目标，~2500 行）；libwavpack（BSD）兜底 | AGPL | 无损/混合可 bit-exact 校验；libwavpack 作对照 |
| DSD→PCM | **自研 Zig**（~400 行） | AGPL | 1-bit 抽取 + 低通，纯信号处理 |
| **MP3 解码** | **自研 Zig**（`fmt/mp3/`，~3500 行：Layer I/II/III + 合成滤波器 + ID3 标签 + Xing/Info 头，§9.4） | AGPL | Layer III 含 IMDCT/霍夫曼/滤波器组/联合立体声，但**可逐位对照 minimp3（CC0）验收**（§17.2）；minimp3（CC0）作参考对照；dr_mp3 移除 |
| **Opus 解码** | **自研 Zig**（P2 CELT / P3 SILK，§9.2） | AGPL | 用户决策（2026-08-17）：解码器完全自研，bit-exact 对照 libopus / FFmpeg opusdec / RFC testvector |
| **Opus 编码** | vendored `libopus` 源码 | BSD-3-Clause | 编码器心理声学模型不自研（§11，`encode/opus_encoder.zig` 封装） |
| **AAC 解码** | **自研 Zig**（`fmt/aac/`，AAC-LC + SBR + PS） | AGPL | 参考 FFmpeg `aacdec*.c`/`aacsbr_template.c`/`aacps*.c` 对照（§17.2）；**LC/PS 100% bit-exact、SBR 内容帧 bit-exact**（2026-09-01 运算顺序对齐后；整体 corr 0.9996，首尾为探测/flush 对齐假象），LC/5.1 100% 逐位 |
| 音频输出（播放设备） | **自研 Zig `device.zig`**（目标）；miniaudio 过渡兜底 | AGPL / MIT-0-PD | 三平台设备 API 自研可控（§15），逐步替换 player.c 内的 miniaudio 调用 |
| 变速变调 | **自研 Zig WSOLA**（目标）；tempo-rs 过渡兜底 | AGPL / MIT | WSOLA 自研可行（§9.6）；tempo-rs 仅作迁移期参考 |
| **FFmpeg（默认主引擎）** | **默认开启**（`-Duse-ffmpeg` 默认 true，链接 `libav*` / `libsw*`） | LGPL-2.1+ | 保持现状解码能力零回归；Zig 内核逐格式验收后**按格式接管**（格式级开关，§8.3）；发布版默认带（LGPL 动态链接 + 合规说明，同现状） |

### 3.3 "自研 vs 引入"决策规则（P2 落地方案）

```
1. 数学/算法复杂度自研可行（容器解析、采样数学、DSP、设备输出）→ 一律自研 Zig
2. 编解码器：自研工作量可控且有可对照参考实现（无损编解码可 bit-exact 校验）→ 自研
   （FLAC、APE、ALAC、WavPack——均有无损 bit-exact 校验 + 参考实现可逐位对照）
3. 其余编解码（Opus）→ 数学复杂度不可自研，引入 Permissive 实现，且必须满足：
   a. 单文件 C（miniaudio）或可 vendored 源码（libopus / OpenCORE）
   b. 源码入库（git），构建期零下载
   c. 许可证 ∈ { MIT / MIT-0 / PD / BSD / Apache-2.0 } 且与 AGPL 兼容
   （MP3 已从本类移出：Layer I/II/III 全链可逐位对照 minimp3（CC0）验收，见 §3.7 裁决变更）
4. 每个 vendored 组件必须登记"是否可自研"的裁决结论（§3.7），新格式一律先按自研评估（AAC 依此由 🔴 改 ✅ 自研，§9.5）
5. FFmpeg（LGPL-2.1+）：**保持为默认主解码引擎**（`-Duse-ffmpeg` 默认开启，动态链接 + 内嵌运行库），
   保证现状解码能力零回归；Zig 内核逐格式验收后**按格式接管**（§8.3），发布版默认带（LGPL 合规说明同现状）；
   明确不引入：faad2（GPL）、libfdk-aac（非自由）、任何 GPL/SSPL/商业源可用（README 红线）
```

### 3.4 与既有 `audio-kernel-no-ffmpeg.md` 的差异

| 项 | C 方案（旧） | Zig 方案（本稿） |
|---|---|---|
| 语言 / 构建 | C11 + CMake + 三平台脚本 | Zig + 单一 `build.zig`，交叉编译 |
| P0 解码器 | 复用 miniaudio 内嵌 dr_mp3/dr_flac/dr_wav | FLAC **自研**（dr_flac 兜底）；MP3 **自研**（minimp3 参考对照，dr_mp3 移除）；miniaudio 仅输出层过渡兜底 |
| libc | 必链 | 内核 freestanding（可选链接） |
| 平台差异 | 隐藏在各平台脚本 | 收敛到构建 target + 自研输出层边界 |
| 依赖面 | miniaudio（含输出层）为主要复用 | 自研优先；仅不可自研编解码器引入（§3.7 裁决）；FFmpeg 保持**默认主引擎**（§8.3），Zig 逐格式接管 |

### 3.5 格式覆盖总表（本地播放器兼容面，P6）

> 覆盖基线对齐 C# 扫描器 `ScannerEngine.cs:33-34` 的扩展名清单
> （mp3/flac/ogg/opus/oga/m4a/aac/wav/ape/wv/dsf/dsd/dff/mp4/aiff/aif），
> 并扩充到常见的 Hi-Res / 无损收藏格式。**容器（解复用）与编解码分离**：容器尽量自研，
> 编解码按 §3.3 规则自研或 vendored。

| 优先级 | 格式 | 容器实现 | 解码实现 | 许可证 | 状态 |
|---|---|---|---|---|---|
| **T0 核心** | MP3 | `fmt/mp3/`（帧头/索引/ID3） | **自研 Zig**（Layer I/II/III 全链 + 合成滤波器 + ID3v2/v1 标签 + APIC 封面 + ReplayGain + Xing/Info 头，minimp3 参考对照，§9.4） | AGPL | **已完成**（接管） |
| **T0 核心** | FLAC | `fmt/flac.zig`（帧/校验自研） | **自研 Zig**（~2500 行：解码 + 全量标签 + REPLAYGAIN + CUESHEET 提示点 + PICTURE 封面图 + ID3v2 前置 + 未知块跳过 + 坏帧重同步，§9.3） | AGPL | **已完成**（接管） |
| **T0 核心** | WAV / AIFF / W64 / RF64 | `fmt/wav.zig` 自研 | 自研（PCM/float/G.711/ADPCM 全系 + GSM + MACE，§9.1） | AGPL | **已完成**（接管） |
| **T0 核心** | OGG/Opus | `fmt/ogg.zig` 自研（P1 完成） | **自研 Zig**（P2 CELT / P3 SILK；编码走 vendored libopus） | AGPL / BSD-3 | **已完成**（接管） |
| **T0 核心** | OGG/Vorbis | `fmt/ogg.zig` 自研 | **vendored stb_vorbis 已接入**（`fmt/vorbis/lib.zig`，pushdata 流式 + granule 定位 seek；多格式 corr 1.0 ±1 LSB） | AGPL / PD | ✅ 已接入 |
| **T0 核心** | AAC / M4A / ADTS | `fmt/m4a.zig` 自研 | **自研 `fmt/aac/`** | AGPL | **已完成（接管）** |
| **T1 无损收藏** | ALAC（M4A 内） | `fmt/m4a.zig` 自研 | **自研 Zig**（~980 行）；`alac.c` 兜底 | AGPL / Apache-2.0 | **已完成**（接管） |
| **T1 无损收藏** | WavPack（.wv） | `fmt/wv.zig`（自研容器 ~150 行） | **自研 Zig**（~1450 行）；libwavpack 兜底 | AGPL / BSD-3 | **已完成**（接管） |
| **T1 无损收藏** | APE（Monkey's Audio） | `fmt/ape/container.zig`（自研容器 ~250 行） | **自研 Zig 解码器**（range coder + 多预测器，~1500 行，参考 FFmpeg `apedec.c` 校验，§9.10） | AGPL | **已完成**（2026-08-17 接管） |
| **T1 无损收藏** | DSD（.dsf/.dff/.dsd） | `fmt/dsd.zig` 自研 | **已接入**：DSF/DFF 容器 + dsd2pcm（对照 FFmpeg dsd.c）+ 8× 抽取；DSF 与 DFF 输出 100% 一致，正弦幅值精确 | AGPL | ✅ 已接入 |
| **T1 常见** | AMR（.amr/.3gp 音频） | `fmt/amr.zig` 自研（#!AMR 头 + 帧重同步） | **vendored OpenCORE AMR-NB 已接入**（92 源按 -x c 编译，与参考 100% 位一致） | Apache-2.0 | ✅ 已接入 |
| **T2 长尾** | WMA（.wma） | — | **生态待评估**（无干净的 Permissive 单文件） | ⚠️ 低优先 | Phase F 可选 |
| **T2 长尾** | MP2 / Speex / AU / CAF | 容器自研 | 按 §3.3 规则逐项评估 | — | Phase F 可选 |
| **T2 长尾** | GSM（WAV/AIFF 容器内） | `fmt/wav.zig` 自研 | **自研 Zig** `gsm.zig`（GSM_MS tag 0x31/0x32/0x1500 + AIFC "GSM "，§9.1） | AGPL | 已完成 |

> **容器 vs 编解码分离的意义**：一个"有视频轨的 MP4"也要能取音频（`fmt/m4a.zig` 只解析 `mp4a`），
> 而"纯音频 M4A（ALAC/AAC）"复用同一容器模块——加格式往往只加一个解码器 + 一行注册，不动容器。

### 3.5.1 格式实现状态总表（2026-08-22 核对）

> 依据当前 `app/core/audio-engine/kernel/fmt/*` 实际代码核实（`decoder.zig` 工厂分发 + probe 枚举），
> 与 §3.5 覆盖表互补：本表聚焦**实现完成度**（代码规模 / 解码器接入 / 逐位验收），
> 非"规划目标"。

| 格式 | 容器 | 解码 | 代码（行） | decoder 工厂 | 验收 | 状态 |
|---|---|---|---|---|---|---|
| **WAV / AIFF / W64 / RF64** | 自研 `fmt/wav/` | 自研（PCM/float/G.711/ADPCM/GSM/MACE） | ~14450 | ✅ `.wav` | ✓ ffmpeg bit-exact | ✅ 接管 |
| **FLAC** | 自研 `fmt/flac/` | 自研（+ID3v2/VORBIS_COMMENT/CUESHEET/PICTURE/ReplayGain/坏帧重同步） | ~3830 | ✅ `.flac` | ✓ ffmpeg bit-exact | ✅ 接管 |
| **MP3（Layer I/II/III）** | 自研 `fmt/mp3/`（帧头/ID3/Xing） | 自研（Layer I/II/III 全链 + synth + ID3v2/v1 + APIC + ReplayGain） | ~2850 | ✅ `.mp3` | ✓ minimp3 逐位 | ✅ 接管 |
| **M4A（ALAC + AAC-LC 双 codec）** | 自研 `fmt/m4a.zig` | ALAC 自研 `fmt/alac/`；AAC-LC 自研 `fmt/aac/`（mp4a+esds → ASC） | ~2300 | ✅ `.m4a` | ✓ 本地参考 100% 逐位 | ✅ 接管（ALAC + AAC-LC + SBR + **PS**；ilst 标签 2026-08-31） |
| **WavPack (.wv)** | 自研 `fmt/wv/` | 自研 | ~1450 | ✅ `.wv` | ✓ ffmpeg bit-exact | ✅ 接管 |
| **APE** | 自研 `fmt/ape/` | 自研（range coder + 多预测器） | ~2040 | ✅ `.ape` | ✓ ffmpeg bit-exact | ✅ 接管 |
| **OGG / Opus** | 自研 `fmt/ogg.zig`（~350，解复用） | Opus 自研 `fmt/opus/`（CELT/SILK）；seek 按 granule 页定位（2026-08-31） | ~7120 | ✅ `.ogg_opus` | ✓ libopus/FFmpeg 对照 | ✅ 接管（seek corr 1.0；OpusTags 标签 2026-08-31） |
| **OGG / Vorbis** | 自研 `fmt/ogg.zig`（复用 granule/页定位） | ✅ `fmt/vorbis/lib.zig`（vendored stb_vorbis） | — | ✅ 接管 | — | ✅ 已接入（Vorbis comment 标签 2026-08-31） |
| **OGG / FLAC** | 自研 `fmt/oggflac.zig`（Ogg-FLAC mapping；callback Reader 喂包） | 复用 `fmt/flac/`（frame/subframe/去相关全复用，metadata 跨包收集） | ~250 | ✅ `.ogg_flac` | ✓ mono/stereo 16-bit bit-exact（192000/192000） | ✅ 已接入（2026-08-31；seek 待补） |
| **AAC / ADTS** | 自研 `fmt/adts.zig`（ADTS 容器，帧定位/坏帧重同步/seek） | **自研 `fmt/aac/`**（AAC-LC + SBR + PS + **Main 预测** + LTP：ICS/频谱/TNS/MS/intensity/PNS/pulse/CCE 耦合 + 前向/逆向 MDCT + 加窗 + QMF/HF 重建 + 参数立体声 + PCE 布局） | ~4600 | ✅ `.aac` | ✓ 本地参考 100% 逐位（§17.2）；**SBR/PS 内容帧 bit-exact**（2026-09-01）；**AAC-Main（AOT1）`hulu`/`am00_88` + ISO 符合性流 mono/stereo/3ch byte-exact**（2026-09-02） | ✅ 接管（AAC-LC + SBR + **PS** + **PCE/CCE** + **Main/LTP 预测**） |
| **DSD (.dsf/.dff/.dsd)** | ✅ `fmt/dsd.zig` 已实现 | ✅ 已实现 | — | ✅ 接管（`.dsd` probe 识别） | — | ✅ 已接入 |
| **AMR** | ✅ `fmt/amr.zig` 已实现（帧重同步 + seek 帧头跳过 2026-08-31） | ✅ vendored OpenCORE AMR-NB | — | ✅ 接管（`.amr` probe 识别） | — | ✅ 已接入（AMR-WB 已修误判 → UnsupportedFormat 回退） |
| **AC-3 / E-AC-3** | 自研 `fmt/ac3/lib.zig`（帧同步/帧头/bsi） | 自研（耦合/重矩阵/DRC/SPX/下混）+ AVLFG + MDCT；mono 修复 | ~4600（含子模块） | ✅ `.ac3`/`.eac3` | ✓ float 参考 corr 1.0（sine/噪声）；mono E-AC-3 corr 1.0 | ✅ 接管（2026-08-31；seek 帧级跳过） |
| **MLP / TrueHD** | 自研 `fmt/mlp/lib.zig` | 自研（无损 + Atmos 标志检测；JOC 逆向放弃见 §9.14） | ~1440 | ✅ `.truehd`/`.mlp` | ✓ bit-exact 40960/40960 | ✅ 接管（2026-08-31；seek 已精确） |

> **说明**：
> - **已接管（✅）**：`decoder.zig` 工厂已分发、`probe.formats.* = true`，可直接播放且经逐位对照验收；
> - **⏳ 规划中**：`probe.zig` 已能识别（`.ogg_vorbis` / `.aac` / `.dsd` / `.amr`），但 decoder 工厂无分支，
>   当前打开返回 `error.UnsupportedFormat`（由 FFmpeg 主引擎兜底，§8.3）；
> - **格式缺口全景**：见 `docs/format-gap-analysis.md`（对照 ffmpeg 227 codec / 368 demuxer 逐项核对：
>   常见缺口 WMA / DTS / AMR-WB，小众缺口 CAF/AU/Musepack 等，其余为游戏/广播专用建议 FFmpeg 兜底）；
> - **ALAC 与 M4A 关系**：M4A 容器承载 ALAC 与 AAC-LC 双 codec（均已接管）——stsd
>   条目分发：`alac` → ALAC 解码器、`mp4a`+`esds`（ASC）→ AAC-LC 解码器；**多声道
>   （chan_config 2–7、11、12、14，含 5.1/7.1）已支持**（2026-08-23 验收：mono/5.1/7.1
>   m4a 与本地参考构建 100% 逐位一致）；**HE-AAC（SBR）已自研支持**（ADTS/M4A，
>   2026-08-23：corr ~0.957，帧对齐）；**HE-AAC v2（PS）已自研实现**（语法/表/DSP/
>   apply/集成完整：位流解析与参考逐帧一致，6 个关键 bug 已修（ileave 基址/hybrid2_re/
>   伪造包络/delay 清零/is34 判定/HA-HB 表 M_SQRT2 缩放 0.707→1.414）+ 全缓冲零初始化
>   消除 ReleaseSafe 未定义行为；立体声源 corr 0.997、能量 0.978、L/R 分离正确，单声道源
>   正确输出 L=R，LC/5.1/HE-v1 无回归；仅剩 1 帧解码延迟差异（mine 早 1 帧，内容无损））；
>   **2026-09-01 运算顺序对齐后**：PS/SBR 内容帧与参考构建 **bit-exact**（见 §9.5，含
>   QMF 窗表符号 ×4、sumSquare 顺序、hfApplyNoise q_filt/噪声索引、getVlc 20 位、m4a 声道切换）。
> - 代码行数按 2026-08-22 `wc -l` 实测，含模块内全部 `.zig`（含注释/测试），仅作规模参考。

### 3.6 格式插件化（comptime 特性开关，P6 的落地）

Zig 在**编译期**按 `build.zig` 选项裁剪模块，默认构建只含 T0，需要时开启扩展：

```zig
const formats = .{
    .wav   = true,   // 自研，T0 默认开
    .flac  = true,   // 自研，T0 默认开
    .mp3   = true,   // 自研（minimp3 参考），T0 默认开
    .ogg   = true,   // 自研解复用，T0 默认开
    .opus  = true,   // 自研解码（CELT/SILK），T0 默认开
    .m4a   = true,   // 自研容器 + ALAC/AAC-LC 双 codec（§9.5/§9.8 已接管）
    .alac  = true,   // 自研已验收（§9.8，随 m4a 接管）
    .wv    = true,   // 自研已验收（§9.9，2026-08-17 接管）
    .ape   = true,   // 自研已验收接管（§9.10，2026-08-17）
    .dsd   = true,   // 自研已接入（§9.11）
    .vorbis = true, // vendored stb_vorbis 已接入（§9.12）
    .amr   = true,   // vendored OpenCORE AMR-NB（§9.13）
    .ac3   = true,   // 自研 Dolby Digital AC-3/E-AC-3（§9.14）
    .mlp   = true,   // 自研 MLP（§9.14）
    .truehd = true,  // 自研 Dolby TrueHD（§9.14）
};

// probe 与 decoder 工厂经 comptime 生成，未开启的格式不编译、不占体积：
pub fn open(path: []const u8, info: *Info) !Decoder {
    inline for (std.meta.fields(@TypeOf(formats))) |f| {
        if (@field(formats, f.name)) {
            const Mod = @import("fmt/" ++ f.name ++ ".zig");
            if (Mod.matches(probe_result)) return Mod.open(path, info);
        }
    }
    return error.UnsupportedFormat;
}
```

- **默认产物体积**：默认含 FFmpeg（现状体积）；每接管一个格式（Zig 格式开关开启）后，对应格式
  的 FFmpeg 路径转为该格式的对照/兜底（编译期可选关闭 `-Dzig-<fmt>=false`）；
- **开启成本**：一条 `build.zig` 选项 + 对应 vendored 源码入库（自研模块无需任何外部源码）；
- **单一许可证审查**：每个格式模块独立审查，`THIRD-PARTY-LICENSES.md` 按开关登记；
- 后端 UI 可暴露"已编译解码器清单"（`format_name` 枚举随 `ready` 事件带出），方便用户排查。
- **与 FFmpeg 主引擎的衔接**：未开启 Zig 的格式由 FFmpeg（默认主）提供（§8.3）；已接管格式优先
  Zig，Zig 解码失败时回退 FFmpeg，**任何格式开关组合都不丢失播放能力**；`-Duse-ffmpeg=false` 时才
  明确报 unsupported（纯 Zig 构建，仅接管格式可播）。

### 3.7 "自研 vs vendored"最终裁决表（P2 落定）

> 每个组件都明确裁决：**自研**（AGPL）/ **自研目标 + vendored 兜底** / **vendored**（不可自研）。
> 新增格式一律先按自研评估（§3.3 规则 4），确认不可自研才落 vendored。

| 组件 | 裁决 | 可自研依据 | 兜底 / 参考 |
|---|---|---|---|
| WAV/AIFF/W64/RF64 容器 | ✅ 自研 | 纯表解析 ~250 行 | — |
| OGG 容器 / OGG muxer | ✅ 自研 | RFC 简单，页/CRC/granule | — |
| MP4/M4A / ADTS 容器 | ✅ 自研 | box 表解析，无数学 | — |
| PCM 转换 / 下混 / SRC | ✅ 自研 | 数学 + 表驱动 | libsamplerate 兜底（若 SRC 不达标） |
| DSP（EQ/loudness/limiter/FFT） | ✅ 自研（移植） | 现有 C 实现 | — |
| DSD→PCM | ✅ 自研 | 1-bit 抽取 + 低通 | — |
| **FLAC 解码** | 🟡 自研目标 | 无损 bit-exact 校验 + FFmpeg/dr_flac 参考 | dr_flac（MIT-0/PD） |
| **APE 解码** | ✅ 自研（已验收） | 无损 bit-exact + FFmpeg `apedec.c` 参考 | 不依赖官方 SDK |
| **ALAC 解码** | 🟡 自研目标 | 无损 bit-exact + Apple `alac.c`（Apache-2.0）参考 | alac.c 兜底 |
| **WavPack 解码** | 🟡 自研目标 | 无损 bit-exact + libwavpack（BSD）参考 | libwavpack 兜底 |
| **变速变调（tempo）** | 🟡 自研目标 | WSOLA 可实现 + 主观/客观对照 | tempo-rs 兜底 |
| **播放输出层** | 🟡 自研目标 | 平台设备 API 直调（§15） | miniaudio 兜底 |
| **MP3 解码** | ✅ 自研（已验收） | Layer I/II/III 全链可逐位对照 minimp3（CC0，MIT-0 系）验收；minimp3（CC0）作参考对照 | minimp3（CC0）参考对照 |
| **Opus 解码** | ✅ 自研（已验收） | 确定性解码可 bit-exact 对照 libopus/FFmpeg；CELT/SILK 自研完成（§9.2） | 参考 libopus / FFmpeg `opusdec.c` |
| **Opus 编码** | 🔴 vendored（不可自研） | 心理声学模型 + 编码器 ~5 万行 | libopus（BSD，源码入库） |
| **AAC 解码** | 🟡 自研目标（AAC-LC 已验收） | 无损 bit-exact + FFmpeg `aacdec.c` 参考 | HE-AAC（SBR/PS）回退 FFmpeg |
| **Vorbis 解码** | 🟢 vendored stb_vorbis（§9.12，已接入） | 有损、无 bit-exact 参考（±1 LSB） | stb_vorbis（PD 单文件） |
| **AMR / WMA / 长尾** | 🔴 vendored 或砍（按需评估） | 低频格式 | 按 §3.3 评估 |

> **裁决判据**：是否无损（有无 bit-exact 校验闭环）+ 是否有可逐位对照的参考实现 + 自研量是否可控。
> 裁决变更（2026-08-22）：**MP3 由 🔴 vendored 改为 ✅ 自研**——Layer I/II/III 解码虽是
> 有损格式，但 minimp3（CC0）作为标量参考可提供逐位对照闭环（PCM 精确一致，§17.2），
> 自研量 ~3500 行可控，故按 §3.3 规则 2 自研；dr_mp3 不再需要。
> 剩余"🔴"（Opus 编码 / Vorbis）是数学复杂度或 ROI 边界，vendored 仍是唯一解。

---

## 4. 架构与模块

### 4.1 目录结构（C 壳保留 + Zig 内核）

```
app/core/audio-engine/                # C 壳保留 + Zig 内核（FFmpeg 依赖拆为可选后端，见 §18）
├── build.zig                         # 单一构建脚本（Zig 0.16；C 壳 + Zig 内核混合，见 §5.1）
├── build.zig.zon                     # 依赖声明（当前应为空——零包依赖）
├── include/
│   ├── archoera_mediaengine.h        # 保留：FFI 契约（Dart，符号面不变）
│   ├── audio_engine.h                # 保留：EngineConfig / pipeline API
│   ├── kernel_bridge.h               # 新增：C 壳 → Zig 内核桥接 API（zk_*，见 §16）
│   ├── miniaudio.h                   # 保留（v0.11.25 已 vendored；player.c 唯一实例化点）
│   └── compat/pthread.h              # 保留（MSVC 构建）
├── src/                              # C 壳（保留，改动最小化；调用部分在 C）
│   ├── mediaengine_lib.c             # FFI 库：export archoera_mediaengine_*（Dart 直连；转调 Zig 桥接）
│   ├── main.c                        # CLI：archoera-audio-engine（UDS/参数语义不变）
│   ├── pipeline.c                    # 管线编排：解码经统一后端接口（Zig 已接管格式 → Zig；其余 → FFmpeg 默认主）
│   ├── player.c                      # miniaudio 自播（MINIAUDIO_IMPLEMENTATION 唯一实例化点）
│   ├── decoder_ffmpeg.c              # 默认主后端：FFmpeg 解码（-Duse-ffmpeg 默认开，§8.3）
│   ├── resampler_ffmpeg.c            # 默认主后端：FFmpeg SRC（同上）
│   ├── encoder.c / pcm_uds.c / fft.c # 保留（Web/CLI 编码、UDS、libfft.so Dart ABI）
│   └── equalizer.c / loudness.c / limiter.c   # 保留（DSP 移植为 Zig 前的过渡；§14）
├── kernel/                           # Zig 内核（本次重写的主体）
│   ├── kernel.zig                    # 桥接导出：export zk_*（C 壳经 kernel_bridge.h 调用，§16）
│   ├── io.zig                        # 输入抽象（Reader：file/mem/callback + peek/seek/abort）
│   ├── probe.zig                     # 格式探测（魔数嗅探）
│   ├── decoder.zig                   # AudioDecoder 接口 + 解码器工厂
│   ├── engine.zig                    # 管线编排（decode→pcm→dsp→encode，被 C 壳桥接驱动）
│   ├── error.zig                     # 统一错误码/错误集合
│   ├── fmt/
│   │   ├── wav/                       # 自研：WAV/AIFF/W64/RF64 + GSM/MACE/ADPCM（已接管，T0）
│   │   ├── ogg.zig                    # 自研：Ogg 页解复用 + granule/CRC（T0）
│   │   ├── m4a.zig                    # 自研：MP4/M4A 音频轨（已接管；ALAC + AAC-LC 双 codec）
│   │   ├── adts.zig                   # 自研：AAC 裸流（T0，Phase C 未实现）
│   │   ├── flac/                      # 自研：解码 + 全量标签（已接管，T0）
│   │   ├── mp3/                       # 自研：Layer I/II/III 全链（已接管，T0）
│   │   │   │                        #   lib.zig / layer3.zig / layer12.zig / synth.zig /
│   │   │   │                        #   huffman_tables.zig / layer3_tables.zig / header.zig /
│   │   │   │                        #   bitreader.zig / id3.zig
│   │   ├── opus/                      # 自研：CELT/SILK 解码（已接管，T0）
│   │   ├── alac/                      # 自研：ALAC 帧解码（已验收，随 m4a 接管）
│   │   ├── wv/                        # 自研：WavPack 解码（已验收接管，§9.9）
│   │   ├── ape/                       # 自研解码器（已验收接管，§9.10）
│   │   ├── dsd.zig                    # 自研 DSF/DFF + DSD→PCM（T1，Phase D）
│   │   ├── vorbis.zig                 # vendored stb_vorbis（T0，Phase D）
│   │   └── amr.zig                    # vendored OpenCORE AMR（T1，Phase F 可选）
│   ├── pcm/
│   │   ├── convert.zig               # 采样格式转换（int→float32 交错）
│   │   ├── downmix.zig               # 声道下混（ITU-R BS.775）
│   │   └── resampler.zig             # 采样率转换（多相 FIR）
│   ├── dsp/
│   │   ├── equalizer.zig             # 10 段 Biquad（移植现状 C）
│   │   ├── loudness.zig              # EBU R128 增益（移植）
│   │   ├── limiter.zig               # 限幅（移植）
│   │   └── fft_abi.zig               # FFT 分析（移植；导出 libfft.so 的 Dart ABI）
│   ├── tempo.zig                     # 自研 WSOLA（目标）；tempo-rs FFI 兜底（§9.6）
│   ├── encode/
│   │   ├── opus_encoder.zig          # libopus 编码（可选模块）
│   │   └── ogg_muxer.zig             # 自研 Ogg 封装（Opus）
│   └── device/                       # 自研设备输出层（目标，§15）
│       ├── device.zig                # 跨平台设备抽象 + 后端选择
│       ├── backend_linux.zig         # ALSA/Pulse/PipeWire（dlopen，零头依赖）
│       ├── backend_windows.zig       # WASAPI（mingw 头，交叉最顺）
│       ├── backend_macos.zig         # CoreAudio（需 macOS SDK）
│       └── player.zig                # 播放语义封装（全解码 WAV、即时 seek；miniaudio 过渡兜底）
├── c/                                # vendored 单文件 C（源码入库，经 Zig 编译；仅过渡/兜底）
│   ├── dr_flac.c                     # FLAC 兜底（自研完成前）
│   ├── alac.c                        # ALAC 兜底（自研完成前，Apache-2.0）
│   ├── wavpack/                      # libwavpack 兜底（自研完成前，BSD-3）
│   └── opus/                         # vendored libopus 源码（仅 Opus 必需，常驻）
├── tempo-rs/                         # WSOLA 过渡兜底（Rust 变速变调静态库，自研完成后删除）
└── tests/                            # Zig test 源（黄金文件 + 一致性对比）
```

> **miniaudio 实例化点（2026-08-16 现状确认）**：`include/miniaudio.h` 已 vendored，**不新建
> `c/miniaudio.c`**——`src/player.c:22-23` 是当前唯一 `#define MINIAUDIO_IMPLEMENTATION` +
> `#include "miniaudio.h"` 处；C 壳保留后实例化点维持不变，Zig `device.zig` 完成后再替换（§15.2）。

### 4.2 数据流（与现状一致，解码经 Zig 桥接）

```
source（本地文件 / Dart 预下载临时文件）
  → C 壳（mediaengine_lib.c 引擎线程）→ pipeline.c → kernel_bridge.h（zk_*）
  → kernel.io.Reader → kernel.probe → kernel.decoder.open（未接管/未支持 → FFmpeg 默认主后端，§8.3）
  → fmt/*.read() → 原生格式交错 PCM
  → pcm.convert → float32 交错
  → pcm.downmix → 目标声道
  → pcm.resampler（passthrough 直通）
  → dsp: EQ → loudness → limiter → tempo → FFT
  → 桌面：PCM 落盘 float32 WAV → player.c（miniaudio；过渡期）自播（skip_encoder）
  → Web/批量：encode.opus_encoder + encode.ogg_muxer → OGG/Opus
```

### 4.3 不变量（迁移护栏，对齐 P5）

1. `archoera_mediaengine.h` 导出符号与语义不变（`create/command/poll_event/session_dir/is_done/destroy`）；
2. `audio_engine.h` 的 `EngineConfig` 字段与 `pipeline_*` 公开 API 语义不变；
3. 桌面输出：float32 WAV + `stream.pcm`（`[pos_ms|samples|channels]+float`）不变（指**文件模式**基线；
   内存模式输出形态见下 §4.3.6）；
4. 采样率语义：player 模式 `output_sample_rate<=0` 跟随源（Hi-Res 直通）；
5. DSP 顺序不变。

> 6.（2026-09-08 新增）**内存播放（不落盘）模式**：桌面播放默认开启，解码 PCM 驻留进程内
>    「全量块列表」（达 cap 才滚动淘汰），频谱经新 FFI `archoera_mediaengine_pcm_window` 拉窗，
>    不写 `stream.wav`/`stream.pcm`；无设备 + 内存模式直接 error（不文件回退）。该能力为
>    **新增可选输出形态**，不破坏上述文件模式基线不变量；完整规格/验收见
>    `docs/audio-memory-playback.md`。

---

## 5. 构建系统：build.zig 与跨平台矩阵

### 5.1 `build.zig` 骨架（Zig 0.16 API；C 壳 + Zig 内核混合产出）

> API 说明：Zig 0.16 已废弃 `b.addSharedLibrary` / `Compile.root_source_file` 旧式，
> 改为 `b.addLibrary(.{ .name, .linkage, .root_module })` + `b.createModule(.{ .root_source_file, .target, .optimize })`；
> C 源经 `root_module.addCSourceFiles(...)` 并入同一模块，系统库经 `root_module.linkSystemLibrary(...)`。

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});          // -Dtarget=...
    const optimize = b.standardOptimizeOption(.{});       // -Doptimize=...

    // 0) Zig 内核模块（解码/DSP；导出 zk_* 桥接，见 §16）
    const kernel = b.createModule(.{
        .root_source_file = b.path("kernel/kernel.zig"),
        .target = target,
        .optimize = optimize,
    });
    kernel.link_libc = true;                              // @cImport 需要
    kernel.addIncludePath(b.path("include"));
    kernel.addIncludePath(b.path("c"));
    // vendored 单文件 C（按格式开关裁剪，§3.6；MP3 已自研，dr_mp3 移除）
    kernel.addCSourceFiles(.{
        .files = &.{ "c/dr_flac.c" },
        .flags = &.{ "-std=c11", "-O3", "-fno-sanitize=all" },
    });

    // 1) FFI 共享库：C 壳（保留）+ Zig 内核混合产出
    const mediaengine = b.addLibrary(.{
        .name = "archoera_mediaengine",
        .linkage = .dynamic,
        .root_module = kernel,
    });
    mediaengine.root_module.addCSourceFiles(.{
        .files = &.{
            // C 壳（保留）：FFI / CLI / 管线 / 播放
            "src/mediaengine_lib.c", "src/main.c",
            "src/pipeline.c", "src/player.c", "src/tempo.c",
            "src/encoder.c", "src/pcm_uds.c", "src/fft.c",
        },
        .flags = &.{ "-std=c11", "-O3", "-fno-sanitize=all" },
    });
    // vendored libopus（可选开关）
    if (b.option(bool, "opus", "vendor libopus") orelse true) {
        mediaengine.root_module.addCSourceFiles(.{ .files = opusSources, .flags = &.{"-O3"} });
    }
    // FFmpeg 默认主引擎（默认开，§8.3；-Duse-ffmpeg=false 得纯 Zig 构建）
    if (b.option(bool, "use-ffmpeg", "build FFmpeg backend as default engine") orelse true) {
        mediaengine.root_module.linkSystemLibrary("avformat", .{});
        mediaengine.root_module.linkSystemLibrary("avcodec", .{});
        mediaengine.root_module.linkSystemLibrary("avutil", .{});
        mediaengine.root_module.linkSystemLibrary("swresample", .{});
        mediaengine.root_module.addCSourceFiles(.{
            .files = &.{ "src/decoder_ffmpeg.c", "src/resampler_ffmpeg.c" },
            .flags = &.{ "-std=c11", "-O3" },
        });
    }
    // Zig 格式接管开关（逐格式，如 -Dzig-flac=true；全部接管后 -Dzig-main=true 使 Zig 升为主）
    if (b.option(bool, "zig-flac", "take over FLAC decoding in Zig kernel") orelse false) {
        mediaengine.root_module.addCSourceFiles(.{ .files = &.{"kernel/fmt/flac_abi.c"} });
    }
    b.installArtifact(mediaengine);

    // 2) libfft.so（独立共享库，Dart fft_bindings 直接加载；Zig 移植后导出，§14）
    const fftlib = b.addLibrary(.{
        .name = "fft",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("kernel/dsp/fft_abi.zig"),
            .target = target, .optimize = optimize,
        }),
    });
    b.installArtifact(fftlib);

    // 3) 测试
    const tests = b.addTest(.{ .root_module = kernel });
    tests.root_module.addCSourceFiles(...);  // 同内核的 vendored C 源
    b.step("test", "Run kernel tests").dependOn(&tests.step);
}
```

> 说明：C 壳的 `main.c` 若需要独立 CLI 二进制（Web/CLI 路径复用），再加一个 `b.addExecutable`（复用同一
> 根模块 + `src/main.c`），`archoera_mediaengine` 共享库则不含 `main.c`；桌面 FFI 客户端只加载共享库。

**格式插件化（P6）在 build.zig 的落地**——特性开关决定 vendored C 源是否编译：

```zig
// 每个格式选项：开启则把对应 vendored C 源加入编译，并把特性常量传给根模块（comptime 裁剪）
const fmt_opts = .{
    "mp3"   => &.{},                     // 自研（无 vendored C 源）
    "flac"  => &.{"c/dr_flac.c"},            // 自研 flac.zig 完成前兜底
    "vorbis"=> &.{"c/stb_vorbis.c"},
    "opus"  => opusSources,                  // vendored libopus（解码+编码）
    "alac"  => &.{"c/alac.c"},
    "wv"    => wavpackSources,               // libwavpack（自研 WavPack 的兜底）
    "ape"   => apeSources,                   // 许可审查通过后（§20）
    "aac"   => opencoreSources,              // vendored OpenCORE
};
inline for (std.meta.tags(@TypeOf(formats))) |f| {
    const enabled = b.option(bool, f.name, "enable " ++ f.name) orelse defaults[f];
    if (enabled) mediaengine.root_module.addCSourceFiles(.{ .files = fmt_opts[f], .flags = &.{"-O3"} });
}
```

### 5.2 三平台产物与交叉编译矩阵

| 宿主 | 目标 | 命令 | 产物 | 备注 |
|---|---|---|---|---|
| Linux | Linux x86_64 / aarch64 | `zig build -Dtarget=x86_64-linux-gnu` | `libarchoera_mediaengine.so` / `libfft.so` / CLI | ✅ 主力 |
| Linux | Windows x86_64 | `zig build -Dtarget=x86_64-windows-gnu` | `archoera_mediaengine.dll` / `fft.dll` / `archoera-audio-engine.exe` | ✅ 无需 MSVC/vcpkg（Zig 自带 mingw 头） |
| Linux/macOS | macOS x86_64 / aarch64 | `zig build -Dtarget=aarch64-macos` | `.dylib` | ⚠️ 见下"macOS SDK 约束" |
| 任一 | 全部 | `zig build -Dtarget=x86_64-windows-gnu -Dtarget=aarch64-macos ...` | 批量产物 | CI 单宿主出三平台 |

**macOS SDK 约束（重要，跨平台边界）**：

- **内核部分（解码/DSP/编码/FFI）是纯 Zig + 无平台头 → 从任何宿主可直接交叉编译 macOS 产物**（Zig 自带 libc 与 zld）；
- **输出层（miniaudio 的 CoreAudio 后端）需要 macOS SDK 头**（`AudioToolbox/CoreAudio`）→
  macOS 全量构建需在 macOS 上执行或显式提供 SDK；
- **决策**：CI 的 macOS job 负责全量构建；Linux 宿主只做"内核验证性交叉编译"（如 `-Dplayer=false`），
  不做全量 macOS 产物。这一边界写进 §15。

**FFmpeg（默认主引擎）的宿主约束**：

- 默认构建（含 FFmpeg）需要 FFmpeg 开发包，**仅在本机构建**（Linux 走 pkg-config / Windows 走 vcpkg
  triplet / macOS 走 brew），不参与交叉编译矩阵；产物仍是同一 `libarchoera_mediaengine.*`，布局不变；
- `-Duse-ffmpeg=false`（纯 Zig 内核 + C 壳）从任一宿主可交叉编译三平台（如上表），供验证性构建与
  渐进接管回归。

### 5.3 与既有构建链的关系

| 现状 | 变更 |
|---|---|
| `app/core/audio-engine/CMakeLists.txt` | **删除**，改用 `build.zig`（FFmpeg 主引擎的探测/链接逻辑迁入 `-Duse-ffmpeg` 分支，默认开） |
| `app/core/audio-engine/rebuild-engine.sh` | 删除（不再有 FFmpeg 自编译） |
| `app/core/audio-engine/build/`（FFmpeg 内嵌库） | 删除（FFmpeg 内嵌运行库逻辑迁入 build.zig/打包脚本，行为同现状） |
| `app/core/audio-engine/src/decoder.c / resampler.c` | 解码路径拆为：`decoder_ffmpeg.c / resampler_ffmpeg.c`（默认主，§8.3）+ Zig 桥接（逐格式接管） |
| `app/core/build-linux.sh` / `build-macos.sh` / `build_windows.bat` | 收敛为 `zig build` 包装脚本（每平台一条 `zig build -Dtarget=...`，默认含 FFmpeg）；纯 Zig 构建额外加 `-Duse-ffmpeg=false` |
| `app/vcpkg.json` | `ffmpeg` 保留为**默认必需**（标注注释：Zig 全部接管后可改 feature）；`nlohmann-json` 属 scraper、`taglib/curl/openssl/sqlite3` 属其他模块、`pkgconf`(host) 保留，均不动；`opus` 改走 vendored（源码入库） |
| `.github/workflows/build-*.yml` | 默认 job 统一调 `zig build -Dtarget=...`（含 FFmpeg，现状回归）；新增 job 覆盖 `-Duse-ffmpeg=false` 纯 Zig 渐进接管回归 |

---

## 6. 输入与 IO 层

### 6.1 `kernel/io.zig`（Reader 抽象）

```zig
pub const Kind = enum { file, memory, callback };

pub const Reader = struct {
    kind: Kind,
    // file / memory 形态
    path: ?[]const u8,
    data: ?[]const u8,
    pos: u64,
    size_hint: u64,
    // callback 形态（预留：fd / 管道 / 未来流式）
    on_read: ?*const fn (ctx: *anyopaque, buf: []u8) usize,
    on_seek: ?*const fn (ctx: *anyopaque, off: i64, whence: i32) bool,
    ctx: ?*anyopaque,
    aborted: std.atomic.Value(bool),

    pub fn openPath(path: []const u8) !Reader { ... }          // std.fs.File
    pub fn openMem(data: []const u8) Reader { ... }
    pub fn peek(self: *Reader, buf: []u8) usize { ... }        // 不消耗
    pub fn read(self: *Reader, buf: []u8) !usize { ... }       // 消耗
    pub fn seek(self: *Reader, off: i64, whence: std.fs.File.SeekOrigin) !void { ... }
    pub fn size(self: *Reader) !u64 { ... }
    pub fn abort(self: *Reader) void { self.aborted.store(true, .seq_cst); }
};
```

- 内部带缓冲（16~64KB），`peek` 供探测回溯魔数；
- **freestanding**：`std.fs` 基于 Zig 系统调用层，不依赖 libc，三平台一致；
- `aborted` 原子标志由所有 `read/seek/peek` 检查（§13 中断），亦为网络流的断流/seek 中断机制；
- **网络输入双路径**（高并发目标见 §8.4 / 决策 #16）：
  1. **预下载本地**（现状，P5 保留为回退）：Dart 预下载临时文件后给本地路径——简单可靠，仍是默认路径；
  2. **HTTP 直连流式**（2026-09-08 目标，与 §8.4 并行开展）：引擎直接消费远端流，经 `Reader.callback`
     形态接入——`on_read` 读 socket / 解 chunked，`on_seek` 发 Range 重定位（`whence` 见 io.zig 头注释），
     `ctx` 由宿主提供。每路一个 callback Reader = 一路轻量实例，128 路共享同一格式模块，开销仅为
     每路私有缓冲 + 解码状态（几十 KiB 级），不再为每路拉起一整套引擎；
- **零网络栈原则（P2 不变）**：传输层（socket / TLS / Range / 重定向）全部由 C 壳 / 宿主注入，
  内核经 `callback` 只消费字节流——内核仍零 curl/openssl 依赖；不支持网络栈时退回路径 1。

---

## 7. 格式探测

`kernel/probe.zig`：读前 64 字节（并解析/跳过 ID3v2 头）做魔数嗅探，返回 `Format` 枚举：

| 魔数 / 特征 | Format | 解码模块 |
|---|---|---|
| `OggS` + `OpusHead` | `.ogg_opus` | `fmt/ogg.zig` + `fmt/opus.zig` |
| `OggS` + `vorbis` | `.ogg_vorbis` | `fmt/ogg.zig` + `fmt/vorbis.zig`（T0，Phase D） |
| `fLaC` | `.flac` | `fmt/flac.zig` |
| `RIFF`+`WAVE` / `RIFX` / `RF64` / `w64` / `FORM`+`AIFF` | `.wav` | `fmt/wav.zig` |
| `ID3` 或 MPEG sync（`0xFF Ex/Fx`） | `.mp3` | `fmt/mp3/lib.zig` |
| `ftyp`（box size + brand） | `.m4a` | `fmt/m4a.zig`（AAC / ALAC 由 `moov/atoms` 内 codec 判定） |
| ADTS sync（`0xFF F1/F9`） | `.aac` | `fmt/adts.zig` |
| `MAC ` | `.ape` | `fmt/ape/`（T1，已接管） |
| `wvpk` | `.wv` | `fmt/wv.zig`（T1） |
| `DSD ` / `FRM8`+`DSD `（dff） / `ID3`+`DSD `（dsf） | `.dsd` | `fmt/dsd.zig`（T1） |
| `#!AMR` / AMR 帧头 | `.amr` | `fmt/amr.zig`（T1，Phase F） |
| `FORM`+`AIFF` 已在 `.wav`（AIFF 是 RIFF 变体） | — | — |
| 其余 | `.unknown` | 返回带原因错误 |

> **M4A 容器内多编解码**：`fmt/m4a.zig` 解析 `moov` 后按音频轨 `stsd` 的 codec 四字符码分发
> （`mp4a.40.2` → AAC、`alac` → ALAC），同一容器模块承载 AAC 与 ALAC（§3.5 容器/编解码分离）。

- `probe` 返回 `error.UnsupportedFormat` 时，`engine.zig` 经 FFI 事件上报 `{"type":"error",...}`；
- 冲突消解：ADTS vs MP3 sync 需二次判定（ADTS 校验 `layer` 位 + 帧长合法性）；
- 未开启的格式开关（§3.6）在 `probe` 中直接判 `unsupported`（不误报"已支持"）；
- **与 FFmpeg 主引擎的衔接（§8.3）**：`probe` 判定 `unsupported`（未支持 / 未开启）的源交由
  FFmpeg 主后端重试（默认主，`-Duse-ffmpeg` 默认开）；已接管的格式（Zig 格式开关开启）优先 Zig，
  Zig 失败回退 FFmpeg；`ready`/`error` 事件带 `backend` 字段（`"zig"` / `"ffmpeg"`）便于排查。

---

## 8. 解码层设计

### 8.1 统一接口 `kernel/decoder.zig`

```zig
pub const Info = struct {
    sample_rate: u32,
    channels: u8,
    bits_per_sample: u8,   // 原生位深
    is_float: bool,        // 原生是否 float
    duration_us: i64,      // 精确>0 / 估算用 duration_known 区分；-1=未知
    duration_known: enum { exact, estimate, unknown },
    codec_name: []const u8,
    format_name: []const u8,
};

pub const Decoder = struct {
    vtable: *const VTable,
    ctx: *anyopaque,
    pub const VTable = struct {
        read: *const fn (ctx: *anyopaque, out: []u8, max_samples: usize, out_channels: *u8) Error!usize,
        seek_ms: *const fn (ctx: *anyopaque, ms: i64) Error!void,
        position_ms: *const fn (ctx: *anyopaque) i64,
        deinit: *const fn (ctx: *anyopaque) void,
    };
};

pub fn open(path: []const u8, info: *Info) !Decoder { ... }  // probe → 工厂分发
```

- 每个 `fmt/*.zig` 实现一个 `open` 返回上述 `Decoder`（data 区分配器统一用内核分配的 allocator）；
- **输出为原生格式交错 PCM**（保留位深），采样转换由 `pcm/*` 统一做——与现状
  `resampler_set_input_format` 的"延迟初始化"语义对齐，且 `Info` 在 open 时已知，可提前建转换器；
- `position_ms` 由各模块累计 `read` 输出的样本数提供（替代现状 `resampler_get_output_samples`）。

### 8.2 解码器工厂

```zig
fn open(path, info) !Decoder {
    const io = try kernel.io.Reader.openPath(path);
    const fmt = kernel.probe.probe(&io);      // 魔数嗅探
    return switch (fmt) {
        .wav  => fmt.wav.open(&io, info),
        .flac => fmt.flac.open(&io, info),    // 自研；dr_flac 兜底
        .mp3  => fmt.mp3.open(&io, info),    // 自研 fmt/mp3/lib.zig（minimp3 参考）
        .ogg_opus => fmt.ogg.open(&io, info),
        .m4a  => fmt.m4a.open(&io, info),
        .aac  => fmt.adts.open(&io, info),
        else  => error.UnsupportedFormat,
    };
}
```

- allocator：`engine.zig` 传入（`std.heap.c_allocator` 或自建 GPA），模块不自分配全局状态；
- 无全局变量 / 无静态注册表，天然可多实例并发（转码线程模型与现状一致）；
- 高并发（128 路）下该硬编码 `switch` 演进为显式**模块注册表 + 实例簿记**（主控），见 §8.4（决策 #16）。

### 8.3 FFmpeg 默认主引擎与 Zig 渐进替换（`-Duse-ffmpeg` 默认开启，2026-08-16 决策）

> 定位：**FFmpeg 保持为默认主解码引擎**（行为同现状，零回归），保证 Zig 内核覆盖不到的格式
> （长尾、未来平台新编码）始终可播；Zig 内核逐格式成熟后**按格式接管**，全程可回退、可对照。

- **实现形态**：随 C 壳保留 `src/decoder_ffmpeg.c`（`avformat_open_input` + `avcodec` 解码）与
  `src/resampler_ffmpeg.c`（`swr_convert`），封装为 C 壳 `pipeline.c` 内部统一的"解码后端"接口；
  Zig 内核（桥接 `zk_*`）与 FFmpeg 后端对 `pipeline.c` 完全透明；
- **主/接管判定**：格式级 Zig 开关（如 `-Dzig-flac=true`）开启的格式**优先走 Zig**，其余走 FFmpeg；
  已接管格式 Zig 解码失败时自动回退 FFmpeg；未接管格式始终 FFmpeg（与现状完全一致）；
- **编译期开关**：`-Duse-ffmpeg`（默认 **true**，Linux 走 pkg-config / Windows 走 vcpkg triplet /
  macOS 走 brew，仅本机构建，§5.2）；产物仍是同一 `libarchoera_mediaengine.so/.dll/.dylib`，
  Dart 侧零感知；`-Duse-ffmpeg=false` 得纯 Zig 构建（仅接管格式可播）；
- **Zig 升为主**：全部 T0/T1 格式验收后，`-Dzig-main=true` 使 Zig 成为默认后端（FFmpeg 仍保留
  为可选主引擎选项），**默认构建仍为 FFmpeg 主**，由用户/构建方决定；
- **可观测**：`ready` / `error` 事件带 `backend` 字段（`"zig"` / `"ffmpeg"`），监控接管率与回退率，
  为后续收敛提供数据；
- **收敛目标**：每格式 Zig 验收（§17.2 对照）后按格式接管；全部 T0/T1 验收后支持 `-Dzig-main=true`
  升主，但 FFmpeg 主引擎作为稳定默认持续保留，不强制移除。

### 8.4 进程内模块化引擎：1 主控 → N 模块 → M 实例（高并发，决策 #16，2026-09-08）

> 动机：真实场景要求**同时 128 路**解码/解析（HTTP 直连多路、批量 tag/元数据、扫描/响度分析、批量转码、
> 多路音效叠播）。FFmpeg 模型下每路都需一套完整 `AVFormatContext + AVCodecContext`（含每实例重复的
> 模块初始化与状态），128 路开销爆炸；且其内部模块化不对外暴露，无法"共享一个轻量内核"。
> 自研内核以**全局只读模块 + 轻量实例**从根本上规避该模型。

**三层模型（状态/能力/簿记分离，互不混淆）**：

| 层 | 职责 | 现状载体 | 数量 |
|---|---|---|---|
| **模块 Module** | 一种格式的*能力*：probe / open / close 函数指针 + 全局只读表 | `fmt/*.zig`（纯函数 + `comptime const` 查表） | 每格式**进程内 1 份**，任意实例共享 |
| **实例 Instance** | 一路源（文件 / 内存 / HTTP 直连 callback）的*私有状态*：Reader、demux 游标、解码器上下文、pts、缓冲、元数据 | `decoder.Decoder`（decoder.zig:152，vtable + ctx） | 每模块 **0..M** 份 |
| **主控 Registry** | 探测 → 按格式分派到模块 → 开出/回收实例 → 簿记（实例计数、资源上限） | `decoder.open()` 的硬编码 `switch`（decoder.zig:194，待收敛） | 全局 **1 份** |

```
宿主 / C 壳（FFI 调用面；内核已自持 Master + Pool 线程，§16.1 修订 2026-09-09，
见 docs/engine-master-pool-design.md）
   │  open(src: path | memory | http://…)
   ▼
kernel.Registry（主控：簿记 + 限额 + 懒加载，全局一份）
   │  ① probe 嗅探  ② 按格式分派  ③ 簿记 ++/--
   ├─ 模块 FLAC（只读表）──── 实例 1 … 实例 n
   ├─ 模块 MP3 （只读表）──── 实例 1 …
   └─ 模块 OGG/OPUS …         （每实例 = Decoder：Reader + 私有解码状态）
```

**不变量（多路隔离的生命线，对照 FFmpeg 做不到之处）**：

1. **模块全局只读、实例私有可变**：模块只含函数指针与 `comptime const` 查表，零可变成员；
   一切运行时状态（比特流游标、预测器、pts、Reader 位置）只存在于实例 ctx。实例绝不写模块共享区，
   否则 128 路互相污染 → 杂音/崩溃。现状 `fmt/*` 已是该形态，注册表不改变此约定。
2. **内核自持调度线程（修订 2026-09-09，取代原不变量 2"内核不持线程"）**：主控 = Master 事件
   线程 + Pool worker，**全归 Zig 内核持有**（`docs/engine-master-pool-design.md` §2.1/§3.1/§5.4）；
   主控只做"簿记 + 分派 + §5.5 容量调节"，运行期零堆分配、无失败路径、不做解码。并发执行在池内
   M 线程。簿记计数用原子量即可，无需锁。sync 直通（调用线程驱动单实例）保留为回归基线。
3. **零拷贝边界**（PDF/方案共识）：`Sync-Direct` 单线程路径才可能零拷贝；一旦跨线程入队
   （实例输出要移交宿主线程池消费者），内存归属变化，packet 必须拷贝。主控不承诺跨线程零拷贝。
4. **资源上限护栏**：主控簿记 `opened` 计数与 `cap`（文件句柄 / 内存双护栏），超限报
   `error.InstanceLimit`；宿主侧另行并发限流，防 128+ 路把 CPU / fd 打满。HTTP 直连实例极轻
   （每路几十 KiB 级缓冲 + 状态），瓶颈主要在 fd 与网络吞吐而非内存。
5. **实例生命周期即收即放**：批量 tag 属"开→解析→关"短生命周期，主控只登记不缓存；
   长生命周期（持续解码）实例才进簿记/限额。128 路批量 tag 用宿主 worker 池顺序轮转即可，
   不必每个常驻。

**与 FFmpeg 兜底的关系**：模块化**只覆盖 Zig 接管格式**（§8.3）。未接管格式仍走 FFmpeg
per-context 兜底；每按格式接管一份，可模块化并发的覆盖面扩大一份——因此**逐格式接管越快，
模块化的经济性兑现越快**。

**演进路径（Phase G，§19）**：`decoder.open()` 的 `switch` → 显式 `Module` 描述符表
（probe/open/close 指针）+ Registry 簿记；`io.Reader` 已预留 `callback` 形态（io.zig:23，含
`on_read/on_seek` 与 peek 缓冲），HTTP 直连即以其为新实例的数据通路，与 §6.1 双路径衔接。

### 8.4.1 A/Sync 执行与调度模型：主控 Async × 模块线 Sync（内核二次增强，决策 #17，2026-09-08）

> 术语修订（2026-09-09，弃 await）：本小节「主控 Async」**不是语言级 async/await/协程**；
> 内核采用阻塞 OS 线程 + 事件/状态驱动（`std.Io` condvar/信号 + 原子读格），解码恒 Sync。
> 落地形态以 `docs/engine-master-pool-design.md` §3.1/§5.1 为准（Master 事件线程 = 事件驱动
> 编排，无 await；timed wait 仅低频兜底且由 `task.waitEventTimeout` 保证）。

> **定位（2026-09-08 修订）：本小节属内核的「二次增强」，后置可选。** Phase G 核心（Registry +
> §8.4.2 优先子项 #1–#4）**不依赖**本小节的 Async/Sync——可先以"主控簿记 + 宿主 worker 池 +
> 纯 Sync 解码线"的最小形态跑通，再按需引入 Async 调度与"完成即领"。具体执行/调度形态
> （主控 Async × 工作线程 Sync × 完成即领，进程内）见
> `docs/engine-master-worker-scheduling.md`（源自用户架构草图升级）。

**A/Sync 术语对照（先定语义，避免歧义）**：

| 术语 | 含义 | 适用场景 | 不适用 / 注意 |
|---|---|---|---|
| **Sync 直解（Sync-Direct）** | 单线程、无队列、零拷贝：demux→decode→PCM 一步同步返回 | seek / 校验 / 单路精测 | 跨线程即失去零拷贝（§8.4 不变量 3） |
| **Async 主控** | 主控事件驱动、非阻塞，只做派发 + 簿记 + §5.5 容量调节 | 高并发任务派发 | 修订 2026-09-09：主控落地为内核自持的 Master 事件线程（engine-master-pool-design.md §3.1），不再依赖宿主事件循环 |
| **Sync 模块线** | 分到流的 OS 线程上同步逐帧解码（`Decoder.read()` 循环） | 一切解码执行 | 单流帧级串行；不做帧内并行 |
| **完成即领（pull / eager-next）** | 短任务 Sync 线"干完一件立即向主控领下一件" | 批量 tag / 批量转码 / 扫描 | 需一次最小握手，不做"零同步" |
| **按流分配 + 帧级分时驱动** | 长生命周期流每线持 1..K 路做帧级轮转 | 128 路播放 / HTTP 直连常驻 | 无"完成"事件；主控只管分配与回收 |

> 两个执行面分开定义，避免把"Async/Sync"与"模块/实例"搅在一起（§8.4 三层模型的执行维度）：

1. **主控 = Async（事件驱动、非阻塞）**：主控不在解码路径上忙等。职责只有三件——把任务/流分给
   空闲线、接收"某线完工 / 某流待调度"事件、簿记。空闲时主控处于**等待事件**状态（事件循环 / 回调 /
   上层 async-await 语法糖），不占用任何解码线程。
   - Async 是主控的**逻辑形态**（修订 2026-09-09：主控落地为 Zig 内核自持的 Master 事件线程，
     无需宿主提供事件循环/调度线程；见 `docs/engine-master-pool-design.md` §3.1/§5.4）。
2. **模块工作线 = Sync（阻塞式顺序解码）**：每条"线"（宿主提供的 OS 线程）一旦分到流/任务，
   就在该线程内**同步**驱动实例逐帧解码（`Decoder.read()` 循环）。单流帧间有状态依赖（MP3 Huffman
   上下文 / FLAC 预测 / Opus 内部状态），必须串行——Sync 循环天然正确、零跨线同步。
   - 拒绝在**单流内部**引入帧级 async/多线程：同流拆帧并行无收益且引入状态竞争；Zig async 协程
     是用户态协程，适合 IO 等待，不适合 CPU 密集解码循环（解码循环放 OS 线程跑 Sync）。

**调度规则（按任务形态二选一，主控据此决定派发行为）**：

| 任务类型 | 代表 | 调度 | 主控职责 |
|---|---|---|---|
| **短任务（有终点）** | 批量 tag/元数据、扫描/响度、批量转码 | **完成即领（pull / eager-next）**：M 条常驻 Sync 线，干完一件立即向主控领下一件 | 只维护 next 游标 / 空闲线集合；完工事件唤醒主控派发 → 无线程空转、无中心队列积压、无 IO 过载（并发上限天然 = 线数） |
| **长生命周期流（无终点）** | 128 路同时播放 / HTTP 直连常驻解码 | **按流分配 + 帧级分时驱动**：每线持有 1..K 路流，K 由负载/码率调节 | 只做流的分配与回收簿记（无"完成"事件），避免 1 流 = 1 线的 128 线程重模型 |

- **tag 批量确认走"完成即领"**（用户确认）：纯短任务，无长生命周期实例，主控"登记 → 派发 →
  完工回收"即止；与 §8.4 不变量 5 一致。
- 即便主控 Async，"完成即领"仍有一次最小握手（worker 完工信号 + 领取下一件），这是必要竞态，
  用空闲栈 / 原子即可，不做"零同步"设计。

> **爆炸源定位（回应"复用 FFmpeg 循环帧解码导致开销爆炸"）**：当前生产路径的解码主力仍是
> FFmpeg 兜底面（§8.3 默认主）——每路实例建立完整 `AVFormatContext/AVCodecContext`、跑通用
> send/receive 循环并复制实例状态，128 并发下"每路完整上下文 + 重复初始化"才是爆炸源。Zig 接管
> 格式的实例是自研极简状态机（同步逐帧），单路开销线性且可忽略——**消除爆炸的唯一路径仍是逐格式
> 接管**（§8.3 / §8.4"与 FFmpeg 兜底的关系"），调度模型本身不放大开销。

### 8.4.2 Phase G 优先子项：不依赖 Async/Sync 的性价比动作（决策 #18，2026-09-08）

> 定位：在调度模型（§8.4.1）之外、按"收益/成本"排序的落地清单，让 128 并发**批量 tag/扫描**先于
> 解码接管完成即可摆脱 FFmpeg。

| # | 子项 | 收益 | 成本/备注 | 现状依托 |
|---|---|---|---|---|
| 1 | **元数据专用快路径 `metadata.open()`**：只 probe + 容器 tag 解析，**不构造解码器状态**。批量 tag/扫描只需 demux 层能力，而 demux/tag 是 Zig 全格式都有的——EraAudio"残血"（仅解码能力）不构成阻碍。**A/B 形态（2026-09-08 定）**：新增轻量 `zk_metadata_*` 只读导出（不复用构造完整 decoder 的 `zk_decoder_open`）；per-file 结果走**结构化 extern struct**（`ZkMetaInfo`：采样/时长/codec/format + 标准字段 + tags 数组 + 封面/歌词），**规避 JSON** | 把"每文件一个 FFmpeg 实例"变"每文件一个几十 KiB 的 Zig Reader"，128 场景单点收益最大 | `decoder.open`（decoder.zig:190）仍整体构造解码器；需把 metadata 解析从解码器 open 中拆出复用 | 各 `fmt/*` 容器已解析 tag（decoder.Metadata/Pictures/ReplayGain，decoder.zig:50-149） |
| 2 | **接管门控**：进程内静态"接管位图"（comptime 可导出），未接管格式**直接进 FFmpeg**、接管格式**不建 FFmpeg 上下文** | 消除"每文件先试 Zig probe 失败再回退 FFmpeg"的双倍 open 成本与回退日志噪音（pipeline.c:104-124） | 仅 engine_mode=EraAudio 分支；Stable 默认路径不受影响 | 格式开关（§3.6）+ probe.formats |
| 3 | **N 实例并发 + 千文件批量 tag 基准**：量化单实例 open 微秒与峰值内存、批量 tag 吞吐 | 用数据判断是否真需复杂化主控，避免过度工程（性价比本身 = 先测再优化） | 扩 `kernel/tests/bench`（§17.3 基线之上） | tests/bench |
| 4 | **实例内存池 + Reader 缓冲复用**：批量"开→解析→关"抖动用 arena / 复用缓冲 | 128 并发下消除每文件 malloc/free 风暴 | 保持已落地的 pread、无预读优点 | io.zig Reader |
| 5 | **FFmpeg 依赖文件拆分延后到 Phase F**：`decoder.c`→`decoder_ffmpeg.c` 属文件组织而非运行时问题，不阻断主线 | 避免为它专门停线 | 消掉 FFmpeg 靠运行时门控（#2）+ 逐格式接管，而非文件摆放 | src/decoder.c（未拆分） |

**落地顺序建议**：#1（元数据快路径）→ #2（接管门控）→ #3（基准量化）→ #4（按基准结果打磨）；
#5 放入 Phase F 顺手完成。

> **#1 落地（2026-09-10，A2）**：`zk_metadata_open/close`（结构化 `ZkMetaInfo`/`ZkTag`，
> **无 JSON**）+ `zk_metadata_set/get_concurrency`（scanner 按 `AdaptiveConcurrency`
> 的 CPU/内存指标协商并行度）。内核新增动态库 `libarchoera_kernel.so`；scanner 侧
> `KernelMetadata.cs` 经 P/Invoke 直桥，`ScannerEngine.ParseFile` 内核优先、TagLib 兜底，
> 映射标量/标签/封面/歌词/年份，封面统一写 `${id}.img`。验收：flac 全字段+封面、
> mp3 无标签兜底、内核缺失回退 TagLib 均通过；1000 文件语料内核路径 37ms vs
> TagLib 38ms（含进程启动，基本持平——当前实现仍走 `decoder.open` 构造解码器 ctx，
> **probe-only 不建解码器状态**为后续打磨项，见 #4 与 §8.4.2 子项 #1 原文）。
> C 侧回归 `tests/test_metadata_abi.c`（ctest 14/14）。
>
> **probe-only 推进（2026-09-10）**：机制落地——`decoder.MetadataSession` +
> `registry.Module.meta` / `dispatchMeta`：有 `meta` 工厂的格式走 **probe-only**
> （只解析容器头/标签、持有其分配，**不构造解码器状态**），无则回退完整 `open`。
> 首批实现 **flac**（`flac.openMeta`：解析 STREAMINFO+元数据块、不分配解码缓冲）。
> 其余格式（mp3/wav/m4a/ogg/opus 等）暂回退完整 open，可逐格式补齐 `meta` 工厂。
> scanner 1000 文件语料：**167ms vs TagLib 201ms（−17%，含进程启动）**。
>
> **第二批（2026-09-10）**：**mp3**（`mp3.MetaCtx`/`openMeta`：解析 ID3v2/v1+首帧+
> Xing 时长，不含 `layer3.DecoderState` 与帧/PCM 缓冲；`buildInfo` 泛型化共用）。
> 至此 flac+mp3 走 probe-only（覆盖扫描常见格式）；**wav/m4a/ogg/opus 仍回退完整
> open**——wav open 与 ADPCM/G.711 解码状态初始化交织（~200 行），m4a 需拆 isom+AAC
> 上下文，留待逐格式推进。scanner 语料：**174ms vs TagLib 200ms（min，−13%）**。
>
> **第三批（2026-09-10）**：**wav + m4a** 落地——wav 把 open 主体抽成 `parseAlloc`
> （`open`/`openMeta` 共用，`openCaf`/`openAu`/`finishPcm` 改返回 void，`destroyCtx`
> 抽出复用；解码缓冲本就惰性分配）；m4a 新增 `MetaCtx`（仅 codec/channels/out_bps/
> meta，**不含 ~9MB AAC/ALAC 解码状态**），只解析 moov→trak（样本表仅算时长后释放）
> + udta 标签，委托 codec 与 chan_config=0 回退完整 open。**至此 flac/mp3/wav/m4a
> 四大类走 probe-only**；ogg/vorbis/opus 等仍回退。scanner 1000 文件语料：
> **184ms vs TagLib 248ms（min，−26%，含进程启动）**。
>
> **第四批（2026-09-10）**：**opus / vorbis / ogg-flac** 落地——opus 用 `MetaCtx`
> （Ogg demux+OpusHead+标签，不含 SILK/CELT/重采样器）；vorbis 不再经 stb_vorbis，
> 改用 `ogg.Demux` 取识别头(0x01)/comment 头(0x03) 自解析；ogg-flac 收集 metadata
> packet 后经内存 reader 调 `flac.openMeta`。**probe-only 覆盖**：flac/mp3/wav/m4a/
> ogg(vorbis)/opus/ogg-flac；仅 speex 等少数格式仍回退完整 open。
>
> **第五批（2026-09-10）**：**speex** 落地（`spx.MetaCtx`：Ogg demux+SpeexHeader+
> 标签，不含 Speex 解码器状态/PCM 缓冲；分配登记统一释放）。**至此 Ogg 家族
> （vorbis/opus/ogg-flac/speex）全部 probe-only**；flac/mp3/wav/m4a + 全部 Ogg
> 走快路径，仅 wma/ape/wv/dsd/amr/ac3/dts/mka/mpc/shn/tak/tta 等仍回退完整 open。
> scanner 侧同步把 `spx` 纳入扩展名白名单与内核直桥格式集。

> 关联（2026-09-09）：逐格式**解码效率**专项（非并发/生命周期侧）单列
> `docs/decode-optimization.md`——SCORE 总表被 50× 实时封顶掩盖的 era vs FFmpeg
> 逐格式 ×RT 差距、公共 PCM/convert 地板、MDCT/Huffman 等候选与 `perf` 定位流程，
> 与 #3「基准先行」衔接：先测后优化。

---

## 9. 各格式实现与依赖账本明细

### 9.1 WAV / AIFF / W64 / RF64 —— **自研完成** `fmt/wav/`（Phase A）

> 状态：**已实现并通过 bit-exact 对照验收**（§17.2），可直接开启 `-Dzig-wav=true` 接管。

- 模块结构：`chunk.zig`（容器头/块遍历：RIFF/RIFX/RF64/W64/AIFF，W64 8 字节对齐）、
  `decl.zig`（fmt 解析与 codec 判定）、`g711.zig`（G.711 a-law/µ-law 解码）、
  `adpcm.zig`（ADPCM/DPCM 解码：IMA WAV / MS / IMA QT / DK4 块解码 + OKI / Yamaha /
  Creative CT / ZORK 连续流解码 + SWF 块式位流 + G.722 / G.726 连续位流，多声道 ≤8）、
  `dpcm.zig`（XAN DPCM 块解码）、`gsm.zig`（GSM 06.10 解码）、`mace.zig`
  （MACE MAC3/MAC6 解码）、`lib.zig`（VTable + 输出）；
- 解析 `RIFF/RIFX/RF64/W64/FORM` 容器 + `fmt ` chunk（PCM 整数 8/16/24/32/64 位 /
  IEEE float **16**/32/64 位（float16 为 2 字节 half；**float24 拒绝** → FFmpeg 兜底：
  3 字节 float 无统一位布局，不发明格式）/ G.711 / ADPCM：IMA WAV tag 0x11、MS tag 2、
  OKI tag 0x10/0x17、Yamaha tag 0x20、Creative CT tag 0x200、IMA DK4 tag 0x61、
  DK3 tag 0x62（sum/diff 立体声）、XBOX tag 0x69、SANYO tag 0x125（3/4/5-bit，
  块样本数存 fmt 扩展区 LE16）、XAN DPCM tag 0x594A（块式，每块 2B/通道 predictor
  头 + 每字节 1 交错样本，shift[2] 每块重置 {4,4}）、ZORK DPCM tag 0x0011（bits 8，
  连续流）、SWF ADPCM tag 0x5346（块式 MSB 位流，首 2 bit = nbits 2..5，块头
  22*ch bits）、G.722 tag 0x028F（每字节高 2 位高带 + 低 6 位低带 → 2 帧 s16）、
  G.726 tag 0x0045/0x0014/0x0040/0x0064（MSB 位流，code_size = byte_rate*8/sample_rate
  推导，2..5），解码输出 s16；GSM 06.10：
  WAV tag 0x31/0x32/0x1500（GSM_MS，LSB 位序，块 41..65B = 2 帧 320 样本）；
  AIFF-C `COMM` 压缩类型 "ima4" → IMA QT、"GSM " → 纯 GSM（MSB）、"MAC3"/"MAC6"
  → MACE（块 2B/1B 每声道，每块 6 样本/声道，输出 s16，≤2 声道）；其余 tag →
  UnsupportedFormat 回退 FFmpeg；
- 块解码（IMA WAV / MS / IMA QT / GSM / MACE）：状态按块重训，seek 按整块对齐；
  GSM / MACE 的流式状态（GSM ref_buf/lar/msr，MACE index/factor/level）跨块保持、
  seek 时 flush（镜像 FFmpeg）；IMA QT 跨块保持展开状态（镜像 FFmpeg：step 相同且
  predictor 差 ≤0x7f 时沿用上块状态）；MS ADPCM >2 声道按每通道独立连续段布局解码
  （镜像 FFmpeg adpcm.c 1637-1658，输出交错）；
- 连续流解码（OKI / Yamaha / CT / ZORK）：无块头，每字节 2 个交错 nibble 样本
  （OKI/Yamaha/CT；帧数 = 数据字节数×2/channels）；ZORK 每字节 1 交错样本
  （8-bit 控制量，stereo 声道交替）；open 时按 codec 初始化状态（CT step=511）；
  seek 从 `data` 起点顺序重训练状态（FFmpeg flush 语义），定位仅精确到字节；
- 变长/位流解码（SWF / G.722 / G.726）：状态均跨 read 调用保持、seek 时 flush
  重训练（镜像 FFmpeg）。SWF 块式 MSB 位流（块头 22*ch bits + 数据位流，nbits 2..5，
  每块 ≤4096 样本/通道）；G.722 每字节 2 帧（mono）；G.726 每样本 code_size 位
  （MSB-first，位级游标；帧边界跨字节时保证 bit-exact）；G.722/G.726 仅单声道
  （validate 拒绝立体声 → UnsupportedFormat）；
- 标签元数据：WAV `LIST`/`INFO` 子列表（INAM/IART/IPRD/ICRD/IGNR/ICMT →
  title/artist/album/date/genre/comment）与 AIFF `NAME`/`AUTH`/`ANNO`（pascal
  字符串）解析，填充 `decoder.Info.metadata`；奇对齐、尾部清理、单字段限长
  4KB、截断/超长声明容错（seek 跳过不报错），字符串分配于解码器上下文、
  deinit 释放（生命周期与 Decoder 一致，C 侧只读不释放）；
- 采样循环点：WAV `smpl` chunk（36B 头 + 每循环 24B：type/start/end/playCount）与
  `cue ` chunk（4B 计数 + 每点 24B：id/position，帧偏移相对 data 起点）解析，
  填充 `decoder.Info.loops` / `cue_points`（allocator 分配、deinit 释放；RIFX
  大端字段按容器字节序读取；条目数 clamp 到 chunk 实际承载、截断时保留已解析
  条目，§13.3）；§16.1 桥接可按需暴露，当前内核侧只读；
- 采样率上限放宽至 **4 MHz**：覆盖 DXD 768k 与高频专业 PCM（§17.2 验收行）；
- 输出契约：**原生位深交错小端**（8-bit WAV 无符号 u8 / s16 / s24 / s32 / f16 / f32 / f64），
  G.711 / ADPCM（含 ZORK/SWF/G.722/G.726） / GSM / MACE 解码为 s16；`data` 大小 →
  精确时长；`seek` 直接定位 `data` 内偏移；
- 覆盖现状 `dr_wav` 的全部容器子集；纯表解析，全 Zig 无外部依赖。

### 9.2 OGG / Opus —— **解码器完全自研（已完成验收；CELT/SILK/Hybrid 全支持）**

> 决策（2026-08-17，用户）：Opus **解码器完全自研**（SILK + CELT），bit-exact
> 对照 libopus / FFmpeg 原生 opusdec 与 RFC 6716 官方 testvector（.dec 规范参考）；
> **编码器**仍走 vendored libopus 封装（§11 `encode/opus_encoder.zig`，心理声学
> 模型不在自研范围）。

**P1 地基（已完成，`zig build test` 278/278 全绿）**：

| 模块 | 内容 | 参考对照 |
|---|---|---|
| `fmt/ogg.zig` | OggS 页解析（页头 / lacing 分段表 / **非反射 CRC-32** poly 0x04C11DB7）+ 跨页 packet 重组 + granule 跟踪 + Demux 状态机 | `libavformat/oggdec.c` / RFC 3533 |
| `fmt/opus/header.zig` | OpusHead（channels / pre_skip / gain / mapping family）+ OpusTags 识别 + 整轨样本数 | `oggparseopus.c` / RFC 7845 |
| `fmt/opus/packet.zig` | TOC（RFC 6716 **Table 2**：config 0-11 SILK / 12-15 Hybrid / 16-31 CELT）+ code 0-3 帧分割（xiph lacing 1-2 字节 / padding）+ 每帧样本数 + 带宽 | `opus/parse.c` |
| `fmt/opus/rc.zig` | 32-bit 区间解码（dec_cdf / dec_log / dec_uint / uint_step / uint_tri / laplace / get_raw / tell_frac）+ MSB 位流 + 帧尾反向 rawbits | `opus/rc.c` / libopus `entdec.c` |
| `kernel/opus_dump.zig` | P1 对照工具：Demux 提取 packets + 头部/包解析统计（packet 数 / 模式 / 时长 / granule） | — |

**P1 实测验证**：ffmpeg 编码 3 种模式文件（CELT 128k / SILK 8k / Hybrid 28k voip），
Demux 均提取 **151 packets 与 ffprobe `nb_read_packets` 完全一致**；OpusHead
（pre_skip=312）与末页 granule（144312 → 音频 144000 样本 = 3.0s）核对一致；
packet TOC/模式/带宽/帧大小解析正确（CELT config 31 / SILK config 1 / Hybrid
config 15，均为 20ms 960 样本）。

**后续阶段（已按序推进）**：

- **P2 CELT（已完成，2026-08-17~18，bit-exact）**：`fmt/opus/celt_tables.zig`（全部 CELT 表，
  U(N,K) 组合数经递推校验）、`fmt/opus/fft.zig`（混合基 FFT + 逆 MDCT）、`fmt/opus/pvq.zig`
  （PVQ 解码全路径）、`fmt/opus/celt.zig`（状态 + 全解码链：header/粗细能量/tf/bitalloc/
  quant_bands/后滤波/去加重/重叠相加）。**验收**：`opus_demo -celt_test` 32 种配置
  （4 带宽 × 4 帧长 × mono/stereo）1081 帧 rc tell+rng 与 libopus 完全一致；PCM 对照 libopus
  float 构建：mono 20ms RMSE 1.3e-8（bit-exact）、10ms 帧 2.6e-8、全 32 配置 1.0e-3、
  2.5ms 短帧 2.1e-3（去加重递归浮点精度，非 bitstream 差异）。修复记录：粗能量 laplace 用错
  算法（改 CELT `ec_laplace_decode`）、u8 移位掩码、Zig `@min(i,20)<<1` 编译器 bug、intra 模型
  偏移、final energy 优先级反转 + 公式、stereo transient hadamard deinterleave 命名/漏解。
- **P3 SILK（核心已完成，2026-08-18，mono+stereo bit-exact）**：`fmt/opus/silk.zig` +
  `fmt/opus/silk_tables.zig`（自动生成全部表 + NLSF 码本）。已落地：SILK 区间熵解码
  （`decIcdf`/`decIcdf16`，与 CELT 共用 `ec_dec`）、`decode_indices`（信号/增益/NLSF/音高/
  LTP/种子）、`decode_pulses`（rate_level + shell coder + LSB + 符号）、`decode_parameters`
  （`gains_dequant` + `NLSF_decode` + `NLSF2A` 全链含 Levinson 稳定性 + `decode_pitch`）、
  `decode_core`（逆 NSQ：LTP 重白化/长时预测/LPC 综合）、dec_API 前导（VAD/LBRR + 跳过）、
  **立体声**（MS 预测 + mid_only + `stereo_MS_to_LR`）。**验收**：SILK-only（config 9）与
  SILK 立体声各 301 帧 rc tell+rng 与 libopus 完全一致，内部 16k 样本 bit-exact。
  重采样器（16k→48k，IIR_FIR + up2_HQ + FIR 插值 + delay matrix）已移植，内部 16k bit-exact；
  48k 输出仍有帧边界状态累积差异（RMSE ~0.26，待精化）。
  修复记录：`lbrr_flags` 未初始化触发假 LBRR 跳过、`LSHIFT/RSHIFT` i16/i8 移位回绕（统一提升
  i32）、重采样器状态未清零/`input_delay` 缺失/`lpcFit` chirp 写成乘法。
- **P4 整合（进行中）**：
  - **hybrid 分层（32/32 帧 bit-exact）**：SILK 解码 LP（内部 16k）→ opus_decoder 级
    redundancy 位（`dec_log(12)` + celt_to_silk/redundancy_bytes）→ 同一 `ec_dec` 上
    `celt.decodeFrame(start_band=17)` 解码 HP 并累加。**修复**：① `start_band>0` 时跳过
    postfilter 解码（libopus `if (start==0 && ...)`）；② redundancy_bytes 用
    `ec_dec_uint(256)`（ftb=8 走全范围解码分支，非 `decUint(257)` 的拆分分支），且须按
    libopus 语义 `dec.storage -= redundancy_bytes`（`BitReader.limit` + `RawBits.bytes`
    同步收缩，令 CELT 段超读按 0 填充、rawbits 反向读取不越入冗余区）。实测 32 个
    hybrid 包 rc tell+rng 与 libopus **全部一致**（含 SILK→CELT 模式转换边界包）。
  - **重采样器 48k 输出（完成，全 bit-exact）**：内部 16k 已 bit-exact；48k 输出经修正
    `input_delay`（delay matrix）、以及 dec_API 的 **+2 缓冲偏移喂入**（首样本=上一帧
    末样本 sMid[1]，丢弃本帧末样本）后，**整轨与 libopus 逐样本一致（0 差异）**。此前
    记录的「削波区 1-ULP 漂移」根因是 SILK 解码器本身的两处 bug（见下），非重采样器。
  - **`fmt/opus/lib.zig`（新增，Opus VTable 封装）**：`decoder.zig` 已接线
    `.ogg_opus` → `opus.open`（probe 识别 OpusHead）。含 Ogg 解复用 + SILK/CELT/HYBRID
    全模式 + pre-skip（OpusHead）+ end-trim（末页 granule）+ 输出增益（Q7.8 浮点）。
    局部验收：silk_test（mono）与 silk_st（stereo）整轨 48k s16 PCM 与 libopus
    **逐样本 0 差异**。hybrid 定位（2026-08-18）：SILK LP（重采样 48k）与 CELT HP
    **每帧头部逐样本 bit-exact**（含最后一帧）；仅帧 31（最后 hybrid 帧）尾部
     （输出样本 840+，即模式转换边界区）发散。根因：**CELT 合成层定点状态累积漂移**
     ——CELT-only 文件（fb_st）同样存在（2.6% 样本 >1 LSB，逐帧增至 ~100 LSB），
     系逆 MDCT/重叠相加/后滤波状态累积的舍入差异（rc/位分配全 bit-exact，
     CELT `preemph_memD`、`oldBandE` 状态需精化）。CELT 精化定位（2026-08-18）：
     **去加重公式修正**为 libopus 精确语义 `tmp=x+mem; mem=preemph*tmp; y=tmp`
     （原 `y=x+c*y` 且返回 y[N-1] 语义错误）；`preemph` 依 CELT 模式（float build：
     24k 0.8500061 / 48k 0.92300415，fb_st 与参考一致用 0.85）。**CELT 100% 达成
     （2026-08-19，anticollapse 顺序修复）**：上述「残余」的真正根因并非 FFT/MDCT
     浮点舍入，而是 **anti_collapse 的通道/band 循环顺序**——libopus
     `anti_collapse` 是 **band 外层 + channel 内层**（`for band { for c { ...celt_lcg_rand } }`），
     我原实现按 channel 外层调用（block0 全部 band 再 block1），导致 `celtRng`
     消耗顺序与 lib 不同 → 尾帧（transient，`anti_collapse_rsv=8,on=1`）噪声填充
     290 个系数符号翻转。重构 `processAnticollapse(f)` 为单入口、band 外层 +
     channel 内层后：fb_st（CELT-only，含 transient/stereo/anticollapse 尾帧）与
     celt_test_st **f32 与 s16 双路径均 100% 逐位一致**（576000/576000 与
     577680/577680，diff=0）。验证工具 `opus_dump` 新增 `--s16` 输出（`s16FromF32`：
     `float2int(8388608*v)` 截断 → clamp ±0x007fff00 → `(s+128)>>8`，与 opus_demo
     RES2INT24→s16 链逐位一致）。
     hybrid→CELT 模式转换淡入（pcm_transition cross-fade）尚未实现。
  - **SILK 立体声修复（本会话定位，silk.zig/lib.zig）**：
    ① `stereoDecodePred` 用 `SMLABB`（libopus 16×16 乘累加），原误用 `SMLAWB`（移位 16）；
    ② 反量化步长常数 `SILK_FIX_CONST(0.1,16)` 需 **+0.5 舍入**（6554 非 6553）；
    ③ `decodeFrame` 解码成功后须 `prev_signal_type = indices.signal_type`（影响后续帧
    的 voiced PLC 判定）且清 `first_frame_after_reset`（否则 NLSF 插值被强制关闭，
    A 系数偏差 → 帧 3 起累积发散）；④ `lpcInversePredGainQa` 缺失循环后 k=0 反射
    系数更新（稳定化迭代多跑一轮 → A 系数 1-ULP 漂移，后续帧累积）；⑤ 重采样器喂入
    须精确复刻 dec_API `&samplesOut1_tmp[n][1]`：单声道 `{decoded[319]_prev, d[0..318]}`，
    立体声 MS→LR 后 **`{x1[1], L[0..318]}`**（x1[1] = 上一帧 sMid[1] ± 本帧插值 side[0]，
    即 MS_to_LR 输出的 out_l[1]/out_r[1]），且 out_l/out_r 需 +2 偏移（decoded 在
    [2..fl+2]）；⑥ 侧声道 `dec1` 状态须跨包保留（仅 `n_frames_decoded` 每包清零，
    否则侧声道 VAD/LBRR 前导被跳过、rc 错位）；⑦ 单声道包 + OpusHead 双声道 → 复制
    mono 到双输出声道。
  - **SILK PLC（实现，silk/PLC.c 移植）**：`PlcState` + `plcUpdate`（好帧）/ `plcConceal`
    （丢包）/ `plc` 调度 + `glueFrames`（丢失→正常边界能量淡入，`SQRT_APPROX`）+ `decodeLostFrame`
    入口。**修复**：`BWE_AFTER_LOSS_Q16` 应为 **63570**（误用 64536）；好帧解码后须
    `lossCnt=0` 且顺序在 `glueFrames` 前；`SMULWW/SMLAWB` 改回绕语义（匹配 gcc 补码回绕，
    正常解码无溢出则不变）。`sqrtApprox` 的 `(24-lz)&31` 须用 i32 运算（CLZ32 返回 u6，
    lz>24 时 u6 下溢 panic）。
  - **PLC 完整对照（2026-08-21，`plc_test` vs `opus_demo -lossfile`）**：silk16 全 37 包
    任意单点丢包（lost@1/5/8/14/20/25/30/33/36）与连续多包（lost@14×2/20×3/28×2/5×3）
    全部 **100% 逐位精确**。对齐约定：mine 跳过 pre_skip 312 样本，ref 完整，
    `mine[i] vs ref[i+624]`；`lost@N` 的 lossfile 行号 = N-1（0-based）。关键修复链：
    ① `decodeLostFrame` 须按 `n_frames_per_packet` 循环生成多子帧 PLC（60/40ms 包
    逐 20ms 子帧，`resampleChannelInto` 支持写入偏移）；② **首包即丢 libopus 输出 0 样本**
    （`prev_mode=0`，last_packet_duration=0），非全零帧——`!decoded_any` 时 `interleaveOut(0)`
    直接返回；③ **PLC 帧长 = 上一好帧时长**（libopus `last_packet_duration`），丢包帧自身
    frame_size 不更新 `prev_frame_size`（连续丢包才对齐）；④ **丢包时 nChannelsInternal 用
    上一好帧的 stereo 状态**（`prev_stereo`），非丢包帧的 toc——pkt28 丢失时 pkt27 首个
    stereo 帧被当作 mono PLC；⑤ **mid-only 判定每帧读取**（VAD_flags[fi]，非仅 nfd==0）；
    ⑥ PLC 帧后须更新 `sst.s_mid=[out[fl-2],out[fl-1]]`（mono 分支，供后续 stereo 帧
    resample 输入用）；⑦ `prev_decode_only_middle` 跨帧跟踪（sst 字段），PLC 时
    has_side=!prev dom → side 置 0。libopus 插桩已全部 git checkout 恢复干净。
  - **SILK→CELT 冗余帧 + smooth_fade（2026-08-21，lib.zig）**：frame15 的
    SILK→CELT redundancy（`celt_to_silk=0, rb=134`）此前完全跳过，导致 CELT 首帧
    （frame16）起全部失配。现已实现 `decodeSilkToCeltRedundant`：`OPUS_RESET_STATE`
    等价 flush + `start_band=0` + 独立 `ec_dec` 解码 5ms（F5=240）冗余帧，再以
    `window²` 权重 `smooth_fade` 混合进 pcm 尾部 F2_5，并**在 interleaveOut 之前**
    应用（此前在之后导致 smooth_fade 修改不生效）。同时跟踪 `prev_redundancy`
    （`redundancy && !celt_to_silk`），frame16 因 `!prev_redundancy` 不满足而
    **不 reset CELT**，直接沿用冗余帧解码后的 CELT 状态。`decodeRedundancy` 返回
    `RedundancyInfo{has, celt_to_silk, bytes}` 供后续使用。
  - **sc2 整轨对照（SILK×15→HYB×1→CELT×34，2026-08-21）**：修复合用/降采样
    `out_len=fl*3` 硬编码为 `fl*(48/silk_fs_khz)`、hybrid deemphasis 改 float 域
    累加（`accum` 参数）后，再补上冗余帧 + smooth_fade + `prev_redundancy`，
    **整轨 99.14% 逐位精确（94558/95376）**，剩余差异全部 ≤4 LSB：frame15
    （HYB，SILK+CELT 分层累加舍入）±1~4 共 813，其余帧零星 ±1（共 5）。
    此前 frame16-25（CELT 段）1920/1920 全失配 → 现 0 差异。
  - **8k SILK（silk8，config=0x18/0x10/0x08/0x00，2026-08-21）**：修复 NLSF 表
    `silk_NLSF_CB_NB_MB` 的 `quant_step_size_q16`（应 0.18→11796，was 9830）与
    `inv_quant_step_size_q6`（应 356，was 427）；`prepSilk` 的 `nFramesPerPacket`/
    `nb_subfr` 映射（60ms→nfpp=3/每次解 20ms 子帧共享 rc）、`decodeSilkFrame`
    循环 nfpp 次 + `resampleChannelInto` 支持写入偏移、`prev_last` 跨子帧延续；
    修复 mono→stereo 切换的 3 个状态问题：**libopus 在 mono 帧也更新
    `sStereo.sMid`**（mine 的 mono 分支补 `s_mid=[out[fl-2],out[fl-1]]`）、
    **mono→stereo 切换时把 ch0 resampler 状态拷给 ch1**（dec_API.c:223）、
    **mid-only 标志每帧都读**（非仅 nFramesDecoded==0，dec_API.c:294）。
    **整轨 100% 逐位精确（96336/96336）**。libopus 侧插桩打印均已清理；
    mine 侧 debug 打印与 db 字段已全部移除（2026-08-21），sc2 回归 99.14% 无退化。
  - **ffmpeg libopus 全链路对照（2026-08-21）**：用 `ffmpeg -c:a libopus` 编码 3s 立体声
    WAV 为 Ogg/Opus（SILK voip 16k@20ms、CELT audio 128k@20ms、audio 24k@20ms、audio
    64k@60ms），mine（`opus_full_dump`）解码对照 libopus（`opus_demo -d` 裸流）：
    **全部 100% 在 ±1 LSB 内（maxd=1）**。修复：**`decodeCeltPacket` 多帧包（60ms=3×20ms）
    `written` 未乘 `f.channels`**，导致第 2/3 子帧覆盖前帧写入（0-100% 错位）——
    现 `pcm_buf[(written+i)*channels+c]`。mine 尊重 granule（total_valid）截断输出
    （3s 文件输出 144000 样本），opus_demo 输出含编码 padding（146880）属正常差异。
    剩余差异全部为 f32→s16 舍入边界 ±1 LSB。
- **CRC 注意**：Ogg 页 CRC 用**非反射** CRC-32（poly 0x04C11DB7），
  Zig `std.hash.Crc32` 是反射（zlib）变体，已自写 256 项表（§3.2）；已用真实
  Ogg 页校验匹配。
- **Seek（2026-08-31，已验证 corr 1.0）**：`fmt/ogg.zig` 新增 `Demux.reset()` 与
  `seekToGranule()`（逐页扫 granule 找目标页 → 字节定位 → 清重组状态）；
  `fmt/opus/lib.zig` `seekMsImpl` 按 **granule = ms×48 + pre_skip** 页定位 + 解码
  丢弃到目标样本。**关键修复**：seek 后 `pre_skip_left` 不应重置（pre-skip 只在从头
  解码时消耗），否则位置少跳 pre_skip。验证：5 个位置（100/300/700/1000/1900ms）
  输出 vs `ffmpeg -ss` 全部 **corr=1.0000 @ 偏移 0**（噪声样本，SILK/CELT 重置后
  与 FFmpeg 解码一致）。
 - **OpusTags（2026-08-31，已实现）**：`OpusHead` 后的 OpusTags 包解析（RFC 7845 §5.2：
   vendor + N×"KEY=value"，Vorbis comment 布局），映射 TITLE/ARTIST/ALBUM/DATE/GENRE/
   COMMENT/DESCRIPTION → 6 标准字段 + 全量 tags；deinit 释放。验证：ffmpeg 带标签样本
   6 字段 + 7 条 tags 全部提取。
 - **编码器**：`encode/opus_encoder.zig` 保持 vendored libopus 封装（§11）。

### 9.3 FLAC —— **自研完成** `fmt/flac/`（2026-08-16，f0-f6 落地 + FFmpeg 对齐扩展）

> 状态：**已实现并通过 bit-exact 对照验收**（§17.2），可直接开启 `-Dzig-flac=true` 接管。

- 模块结构（约 2500 行，全 Zig，无外部依赖）：
  - `crc.zig`：CRC-8 ATM / CRC-16 ANSI；`bitreader.zig`：MSB-first 位读取 + 滚动 CRC-8；
  - `streaminfo.zig`：可选 **ID3v2 前置标签跳过**（FLAC 规范允许，ffmpeg 带 `-id3v2_version`
    转出的文件）→ `fLaC` 头 + 元数据块遍历（显式 switch 判定块类型，未定义值 7..126 /
    127 INVALID → **跳过**（FFmpeg flacdec default 分支 avio_skip 同款容错），不依赖
    `@enumFromInt`）+ STREAMINFO / SEEKTABLE / **VORBIS_COMMENT** / **CUESHEET** / **PICTURE**
    解析；
  - `frame.zig`：帧头解析（UTF-8 帧号、blocksize/sr 扩展位、ch_mode、bps_code、CRC-8）；
  - `residual.zig`：分区 Rice（method 0/1 + escape + 符号折叠）；
  - `subframe.zig`：constant / verbatim / fixed 0-4 / LPC + wasted bits；
  - `lib.zig`：`open` + VTable + 帧循环 + 去相关（left/right/mid_side，32 位 u32 环绕与 33 位
    wide 路径）+ seek（SEEKTABLE 最近点 / 无表估算+CRC-8 同步扫描）+ 输出打包；
- 标签元数据：VORBIS_COMMENT 块（字段长度 LE；TITLE/ARTIST/ALBUM/DATE/GENRE/COMMENT
  （COMMENT 与 DESCRIPTION 同义，首字段优先）→ `decoder.Info.metadata`，键大小写不敏感、
  单字段限长 4KB、字段越界停止该块解析不报 Corrupt）填充 `decoder.Info.metadata`，
  字符串分配于解码器上下文、deinit 释放（生命周期与 Decoder 一致，C 侧只读不释放）；
  **全部条目**（含 TRACKNUMBER/ALBUMARTIST/encoder 等非标准键，key 原样大小写、value 已
  trim、重复键全保留）→ `Metadata.tags`（对齐 FFmpeg av_dict），deinit 统一释放；
- 提示点：CUESHEET 块（CD 目录：头 396B + 每 track 36B + 每 index 12B；index offset（样本，
  相对音频流起点）→ `decoder.Info.cue_points`，`id` 顺序编号、条目数 clamp 到块实际承载，
  §13.3）；`Info.loops` 恒空（FLAC 无采样器循环点）；
- 附加图片：PICTURE 块（FLAC 规范 §5.8 / ID3v2 APIC 布局，字段长度 BE：type / mime /
  description / width / height / depth / colors / data）→ `decoder.Info.pictures`；
  mime/desc 限长 4KB、data 限长 64MiB（§13.3 防超大分配），任一字段越界/截断 → 放弃该图
  不报 Corrupt 且块对齐不破坏后续块；`decoder.Picture`（§8.1）生命周期与 Decoder 一致、
  deinit 释放、C 侧只读不释放；
- **REPLAYGAIN**：`REPLAYGAIN_TRACK/ALBUM_GAIN`（`"±X.XX dB"` → 千分之一 dB 整数）、
  `REPLAYGAIN_TRACK/ALBUM_PEAK`（→ 十万分之一单位整数）→ `Info.replay_gain`
  （`decoder.ReplayGain`，单位对齐 FFmpeg `AVReplayGain`；畸形值保持 null 不崩溃）；
- **坏帧重同步**：帧解码 Corrupt（帧头一致性 / 子帧 / 整帧 CRC-16 失败）→ 从当前位置向后
  扫描合法帧起点（0xFFF8 同步码 + 帧头 CRC-8/一致性校验）**跳过坏帧继续**（§13.3 容错，
  对齐 FFmpeg flacdec 损坏帧跳过语义）；无法恢复且无产出 → Corrupt 透出；
- 输出契约对齐 FFmpeg：bps≤16 → 16-bit 左移 `16-bps` 对齐满幅；bps>16 → 32-bit 左移 `32-bps`；
  交错小端 PCM。
- 接线：`kernel/decoder.zig` 工厂 `.flac` 分支；`kernel/flac_dump.zig` 为对照导出工具
  （stderr 摘要含全部标签 / REPLAYGAIN / 提示点 / 封面）。
- 兜底已不再需要（原计划 dr_flac 取消）。

### 9.4 MP3 —— **自研完成** `fmt/mp3/`（2026-08-22，minimp3 参考逐位验收）

- `fmt/mp3/` 模块分解：
  - `lib.zig` —— 统一解码视图（VTable：open/read/seek_ms/position_ms/deinit），ID3v2 跳过与解析、
    ID3v1 文件尾、Xing/Info 头、时长估算、seek 估算 + 帧同步扫描、int16 交错输出；
  - `layer3.zig` —— Layer III 完整管线（side info / scalefactor / huffman / requant / stereo
    MS+intensity / reorder / antialias / IMDCT36/12/short / bit reservoir / findFrame）；
  - `layer12.zig` —— Layer I/II（bitalloc / scalefactor / dequantize / scf384）；
  - `synth.zig` —— 合成滤波器（DCT-II + 多相 g_win / g_sec / g_aa，mono qmf 特例）；
  - `header.zig` / `bitreader.zig` / `huffman_tables.zig` / `layer3_tables.zig` —— 帧头 / 位读 / 表；
  - `id3.zig` —— ID3v2.2/2.3/2.4（标准字段 + 通用 tags + TXXX + APIC 封面 + UTF-8/16/Latin-1）、
    ID3v1 文件尾、ReplayGain（TXXX REPLAYGAIN_*）。
- **参考对照**：minimp3（CC0）标量路径（`MINIMP3_FLOAT_OUTPUT` + `MINIMP3_NO_SIMD`）作逐位参考，
  参考对照、未并入其源码；全部 Layer I/II/III 向量（minimp3_test 的 l1-fl* / ILL2* / performance*）与真实样本
  （mono/stereo、MPEG1/2/2.5、8k-320kbps、CBR/VBR）PCM 精确一致（worst=0，§17.2）；
- **标签 / 时长**：ID3v2/v1 标签 → `Info.metadata`（含 APIC 封面 → `Info.pictures`、
  ReplayGain → `Info.replay_gain`）；Xing/Info 头 → `duration_known = exact`；
- **seek**：无帧级 seek 表 → 按总帧数（Xing 精确 / 首帧估算）比例估算字节偏移 + 帧同步扫描
  定位最近帧边界（§12.3）；bit reservoir 依赖帧自动跳过到最近可独立解码帧。
- 产出 `Info.codec_name = "mp3"`，`bits_per_sample = 16`（MPEG 音频原生 16 位）。

### 9.5 AAC / M4A —— **解码器完全自研**（AAC-LC 已验收接管；2026-08-23）

> 裁决变更（2026-08-23，用户决策"尽可能自主实现"）：AAC 由 🔴 vendored OpenCORE
> 改为 ✅ **自研 Zig**（`fmt/aac/`）。与 MP3/Opus 同模式：**参考实现逐位对照验收**
> （`reference/FFmpeg` n9.0.1 `libavcodec/aac/aacdec*.c` 浮点路径 + 本地构建无优化
> ffmpeg 作黄金基准，§17.2）；OpenCORE 不再引入。

- **范围（Phase C）**：AOT 2 (AAC-LC) 无 SBR/PS；raw_data_block 元素 SCE/CPE/DSE/FIL；
  CCE/PCE 暂拒（chan_config ≤ 2 mono/stereo）；工具 MS/intensity/TNS/PNS/pulse 全支持；
  HE-AAC（SBR/PS）→ `UnsupportedFormat` 回退 FFmpeg 主后端（§8.3）；
- **模块**（`kernel/fmt/aac/`）：
  - `bitreader.zig` —— MSB 位读 + 非规范序 Huffman 精确匹配 VLC 解码；
  - `asc.zig` —— AudioSpecificConfig（隐式/显式 SBR 信令）+ ADTS 帧头解析；
  - `tables.zig` / `huffman_tables.zig` / `rt_tables.zig` / `mdct_tables.zig` —— 表生成器
    从参考源提取（§3.2/§3.6），运行时初始化表（pow2sf/KBD/sine/cbrt）以本机精确位模式嵌入；
  - `mdct.zig` —— 逆 MDCT 复刻 av_tx 浮点路径（split-radix 单块 FFT），参考源逐位校验；
  - `lib.zig` —— ICS 语法/频谱反量化/TNS/MS/intensity/PNS/pulse/加窗重叠相加 + 输出；
- **容器**：`fmt/adts.zig`（ADTS 裸流 VTable，帧定位/坏帧重同步/seek）；
  M4A 内 AAC 轨（`fmt/m4a.zig` stsd `mp4a` 条目 → esds → ASC 提取 + 逐 sample 喂包）
  **已接线验收**（2026-08-23，§17.2）；HE-AAC（SBR/PS）与 chan_config>2 的
  mp4a 条目 → `UnsupportedFormat` 回退 FFmpeg；
- **输出契约**：s16 交错小端，float ×32768 后 `lrintf`（最近偶数舍入，对齐 FFmpeg
  swresample `av_clip_int16(lrintf(x*32768))`）+ 饱和；
- **验收（§17.2，2026-08-23）**：与本地参考构建（无优化，同源 n9.0.1）s16 输出
  **100% 逐位一致**（3 样本：mono/stereo × sine/粉噪，48k/44.1k）；与系统 ffmpeg
  （LTO+AVX2）99.99%+ 一致，残留全部 ±1 LSB（构建浮点差异，非算法错误）；
- 接线：`probe.formats.aac = true`、decoder 工厂 `.aac → adts.open` 已接入。
- **HE-AAC 验收（2026-08-31 起，2026-09-01 达 bit-exact）**：对照 ffmpeg 验证 ——
  - **SBR（HE-AAC v1）**：`ct_nero-heaac.mp4`（stereo 44100 HE-AAC）输出 **corr 0.9965 @ 偏移 0**（QMF 高频重建浮点差异）；2026-09-01 运算顺序对齐后内容帧与参考构建 **bit-exact**（QMF 窗表符号错误为根因）。
  - **PS（HE-AAC v2）**：`aacPlusDecoderCheckPackage` `File2.mp4`（HE-AACv2）曾 corr ≈ -0.13；**2026-09-01 已 bit-exact**（`ps_st_v2.m4a` 100% 逐位、`ps_File2.mp4` 内容帧逐位）。历史深修过程如下：
    - **修复 1**：`ps_tables.zig` `ff_k_to_i_34` 表错误（索引 60-90 段应为 31/32/33，原写 30/31/31）→ 34-band 模式高频带参数带映射错（已对照 `aacpsdata.c` 修正）。
    - **修复 2**：`sbr.zig` `bs_extension_id==2`（PS）后不跳剩余填充位 → 跨帧位流错位；改 `psReadData` 返回消费位数 + 跳过剩余（对齐 ffmpeg `skip_bits_long`）。
    - **静态对照**（子代理 ×2 + 人工，逐行）：`aacpsdsp_template.c`（hybrid_analysis/decorrelate/stereo_interpolate(_ipdopd)/ileave）、`aacps.c`（hybrid_analysis/hybrid6_cx/hybrid2_re/decorrelation/stereo_processing/hybrid_synthesis）、`aacps_common.c`（ff_ps_read_data/ps_read_extension_data）、`aacsbr_template.c`（sbr_x_gen/ff_aac_sbr_apply PS 集成）、`aacps_tablegen.h`（pd/Q_fract/HA/HB 表）**全部一致**。
    - **运行时参数验证**（文件导出，非打印）：File2 为 20-band（is34=0, nr_iid=20, nr_icc=20, enable_ipdopd=0），top_in=43（kx[1]+m[1]），num_time_slots=16 —— 全部正常。
    - **剩余**：静态全一致 + 参数正常但输出仍错 → **编译 ffmpeg aacps 对比工具**（`/tmp/opencode/ps_compare.c` + mine 转储）定位到决定性证据：**mine 的 `X_low`（AAC 核心 QMF 分析输出）对 File2 指数爆炸**（帧4 起 7.8 → 2.8万 → 41万，146/166 帧 >1000），而 SBR 高频 `Y` 正常（<130）→ PS 输入（`X_saved`）巨大 → 输出 clamp → corr -0.13。**最终定位**：AAC 核心输出正常（<0.3），但 `qmfAnalysis`（QMF 分析滤波器）对 File2 的 **22050 采样率**放大约 140 万倍（0.3 → 41万）→ **根因在 SBR QMF 分析层**（File2 核心 22050 的滤波器系数/状态路径，ct_nero 44100 正常）——非 PS。（2026-08-31）
  - **修复（2026-08-31）**：
    - `sbr.zig` `makeFMaster` 偏移为有符号（负值表），原 `@bitCast(i32→u32)` 使负偏移变正数 → u32 溢出 panic；改 i32 计算 + k0<0 检查（对照 ffmpeg）。
    - **probe ADTS/MP3 误判**：带 ID3v2 标签的 ADTS（如 `File1.aac`）超出探测窗口时，probe 兜底判 MP3 → 改 ID3 后 seek 完整 `identify` 判定（ADTS/MP3/FLAC）。
    - **adts.open 跳过 ID3v2 前导**（`File1.aac` 头部 113 字节 ID3 导致读帧头失败 UnsupportedFormat）。
- **运算顺序对齐（2026-09-01，PS/SBR 达 bit-exact）**：转储 mine 与参考构建（无优化 n9.0.1 浮点标量路径）逐帧对比 DSP 内部，逐级收敛：
  - **QMF 窗表符号错误 ×4**：`sbr_qmf_window_ds[192]/[256]`、`sbr_qmf_window_us[384]/[512]` 丢失源码 `-Q31(...)` 取负 → 值正负相反，单点符号翻转串扰整条 HF 链。修复后 **QMF 分析（X_low）与参考构建逐位一致**。
  - **`sumSquare` 累加顺序**：原 `sum0 += (a²+b²)`（先求和再累加），ffmpeg 为 `sum0 += a²; sum0 += b²`（分两次累加）；`sbrEnvEstimate` 插值分支改用 `dsp.sum_square` 语义。
  - **`hfApplyNoise` q_filt**：原固定用原始 `q_temp[i]`，平滑模式（h_SL≠0）应用平滑后 `q_filt`。
  - **`hfApplyNoise` 噪声索引（决定性）**：原每个时隙都从 `ch_data.f_indexnoise`（帧起始值）开始，且函数末尾回写污染状态；ffmpeg 用组装循环里**每时隙 +m_max 推进的运行 indexnoise**。改为参数传入 + 局部副本 → **Y（HF 组装输出）与参考构建逐位一致**。
  - **`getVlc` 码长上限**：`while (len <= 13)` 应为 20（SBR Huffman 表最长 20 位），长码字帧（包络切换）此前抛 Corrupt 被整帧丢弃 → 输出提前/变短。
  - **m4a 声道切换**：HE-AAC v2 PS 首帧解析后声道 1→2，`readImpl` 帧字节宽/容量须随其后更新，否则输出 framing 错位。
  - 结果：`ps_st_v2.m4a`/`n44_st.aac` **100% bit-exact**；`he_st.aac`/`he_st_v2.m4a`/`ps_File2.mp4` **内容帧 bit-exact**（整体 corr 0.9996~0.9974，差异仅为探测/flush 对齐 + 系统 ffmpeg SIMD 舍入的 ±1 LSB）。
- **元素补全（2026-09-01）**：
  - **PCE（program_config_element，元素 5）**：chan_config=0 时布局由 PCE 定义。实现 PCE 解析 + 动态布局构建（front/side/back/lfe/cc 声道映射到 AV_CH 输出序）+ ADTS/m4a 首帧预热以确定声道数（含 chan_config=0 无 PCE 时按帧内元素推导默认布局的回退）。验证：`ffmpeg -aac_pce` 生成的 ADTS 与 m4a 均 **bit-exact**（corr 1.0/0.99999999）。
  - **CCE（coupling channel element，元素 2）**：实现耦合点（BEFORE_TNS / BETWEEN / AFTER_IMDCT）解析、目标元素表、增益（GET_GAIN=cce_scale^−gain）、依赖耦合（谱域相加）与独立耦合（时域相加）在 spectral_to_sample 三点的应用。CCE 流极罕见、无测试样本，按 ffmpeg 逐位移植（构造正确性）。
- **预测：AAC Main（AOT 1）+ LTP（AOT 4）（2026-09-02）**：
  - **Main 预测器（AOT 1）**：`decodePrediction`（predictor_reset_group + prediction_used）+ `applyPrediction`（672 预测器，`flt16_round/even/trunc` 截断、二阶自适应系数、`a=0.953125/α=0.90625`、分组复位每 30 个），在耦合后、TNS 前应用（对齐 ffmpeg decode_ics/decode_cpe 的 predictor_initialized/复位语义）。**验证**：`hulu_main.flv`（真为 **AOT 1 Main**，此前误判为 LTP）48k 立体声——修复前整体 corr≈0.007 + 每 ~7 帧丢 1 帧，修复后**全部 613 帧内容与参考 ffmpeg 逐字节一致**（仅 ffmpeg ADTS demux 端丢弃的 1 帧异常前导（74B）mine 解码为静音 → 输出多 1 帧纯前导零；LC 对照 `t48_m.aac` 则完全零偏移 byte-exact）。
  - **根因**：`fmt/adts.zig` 建解码器时 **object_type 硬编码 2（LC）**（历史遗留，AOT 1/4 门禁早已放宽），Main/LTP 流被当 LC 解 → 含 predictor 的帧被 LC 分支以 `Prediction not allowed` 拒为 Corrupt 丢弃、其余帧无预测纯 LC 输出（故内容虽对齐仍零相关）。
   - **LTP（AOT 4）**：`decodeLtp` 补 `ltp.present` 位（decode_ics_info 内 ltp.present=1 才跟 lag/coef/used）+ CPE common_window 下 ch1 独立 `ltp.present`（在 ms_present 之前读）；`apply_ltp`（predTime=ltp_state[+2048−lag]·coef → 448/128 拼接加窗（LONG_STOP/START）→ **1024 点前向 MDCT**（`mdct.zig` 新增 `initLtp/transformFwd`，复刻 `ff_tx_mdct_fwd` scatter 折叠 + split-radix FFT + post-twiddle，scale −65536，黄金向量 **bit-exact 1024/1024**）→ TNS 编码向 → used sfb 加回 coeffs）+ `update_ltp`（IMDCT 后 buf_mdct 过渡段存 saved_ltp（复用 coeffs）+ ltp_state 平移；buf_mdct 共享故逐声道紧随各自 IMDCT）。`ch.output` 扩到 2048 对齐 ffmpeg `sce->output`。**LTP 已逐行对照 ffmpeg 审计通过**（加窗/apply/update/共享 buf 时序无误）；真实 AOT-4 流公网/FATE/编码器均不存在（LTP 从未有商用编码器，属死 profile），仅能以"前向 MDCT 黄金向量 bit-exact + 忠实移植"验收，无法端到端比特级验证。
- **符合性流回归（2026-09-02）**：用 FATE ISO 流（`fate-suite.ffmpeg.org/aac/al*/am00_88`）逐一验收，修复三处真实 bug 后 mono/stereo/3ch/Main 全部 **byte-exact**：
  - **pulse 除数为 4 次根**：mine 误用 `cbrt`(3 次根)，ffmpeg 浮点路径为 `co/sqrtf(sqrtf(|co|))`（`al04_44` mono LC 帧2起 ±1..±500 谱纹波 → 现 byte-exact）。
  - **PCE front 声道序**：chan_config0+PCE 的 3/0（front=[SCE,CPE]）ffmpeg 把前中心夹在 L/R 之间；mine 顺序铺到 FL 槽。front 分配改为"奇数声道且首元素 lone SCE → 前中心 FC(2)，其余成对 (FL,FR)"+ 其余排列回退元素序，输出前按 AV 位置**密集重编号**（`al06_44` 3ch → byte-exact）。
  - **PCE 的 cc（coupling）元素误当输出声道 → pcePos(4)=null 直接 Corrupt**：cc 非输出，剔除后 `al07_96/al15_44` 由"整段 Corrupt 丢弃"改为可解码；随后**完整移植 ffmpeg `assign_channels`/`count_paired_channels`/sniff 稳定排序**（front/side/back/lfe 按 `ff_aac_channel_map` layer0 行分配 AV 位、按位值排序成 native 序）替换原先的启发式 → **声道序与 ffmpeg native（chprobe 验证 [FL FR FC LFE …]）一致**。
  - **±1 专项（f32 harness）**：建 f32 级对比（mine 在 s16 打包前 dump 原始 float，对参考构建 f32 输出）定位残余。**确证**：cbrt_tab（用 ffmpeg 奇数根分解算法逐位复刻）、pow2sf_tab（读参考运行时表）均 **0 差异**；差异自 `al07_96` 帧 189 起、集中在两个 CPE 声道，**仅单样本差异且邻样本 float 逐位一致**（如 BR 帧189 采样658：mine≈-3.4e-6 vs ref≈-2.6e-5，×32768 各舍入到 0/-1），即非宽带误差、非表错误，指向 CPE 声道某罕见单样本级 dequant/高频 bin 舍入路径；FC/LFE 及全部 44.1/48k mono/stereo/3ch/Main 仍 byte-exact。根因定位需参考解码器内部 coeffs（超出黑盒），已如实归档（corr≈1.0，听觉无损）。
- **M4A 标签（2026-08-31，已实现）**：`fmt/m4a.zig` `parseMetadata()` 解析
  moov → udta → meta（fullbox，跳过 4 字节 version/flags，**遍历子 box 找 ilst**，
  注意 ilst 前有 hdlr）→ ilst 原子 → data box（version/flags+locale+value）。
  标准映射 `©nam/©ART/©alb/©day/©gen/©cmt/aART/©wrt` → 6 字段（首字段优先），
  其余原子（含 `©wrt` composer、`©too` encoder 等）全量入 `tags`；仅接受
  data_type==1（UTF-8）文本，binary（trkn/covr 等）跳过。生命周期随 `M4aCtx`
  destroyCtx 释放。验证：ffmpeg 生成带标签 ALAC M4A，6 标准字段 + 8 条 tags
  全部提取正确。**缺口**：`covr` 封面图未解析。

### 9.6 变速变调 —— **自研 Zig WSOLA**（目标）；`tempo-rs` 兜底

> 决策（2026-08-15）：变速变调升级为自研目标（§3.7），消除内核中唯一的非 Zig 组件。

- **自研 WSOLA（波形相似重叠叠加）**：`kernel/tempo.zig`——按"时间伸缩"帧级对齐 + 交叉淡化，
  速度 [0.5~2.0]；变调经相位声码器（短窗 STFT + 相位传播）或 WSOLA+重采样组合；~800 行；
- **验证**：与 `tempo-rs`（signalsmith-stretch）主观 A/B + 客观（对齐后互相关/频谱包络）对照；
  质量对语音/乐音可接受（WSOLA 特性）；黄金文件时长伸缩后采样数断言；
- 兜底：`tempo-rs` 静态库保留（`extern fn rs_tempo_*` + `RunStep cargo build`），
  自研完成后移除；
- `HAS_TEMPO` 条件编译语义保留（自研完成前关闭时 tempo bypass）。

### 9.7 音频输出 —— **自研 Zig `device.zig`**（目标）；miniaudio 过渡兜底

> 决策（2026-08-15）：输出层升级为自研目标（§3.7），设计见 §15。
> 现状（2026-08-16 确认）：`include/miniaudio.h` 已 vendored（v0.11.25），`src/player.c:22-23`
> 是**唯一** `MINIAUDIO_IMPLEMENTATION` 实例化点；C 壳保留后 player.c 维持现状，不新建 `c/miniaudio.c`。

- `kernel/device.zig`：跨平台设备抽象（打开/播放/暂停/seek/音量/位置），每平台一个后端；
- 过渡期 `src/player.c` 继续使用 miniaudio（实例化点保持在 player.c）；`device.zig` 完成后，
  对应后端经 `kernel_bridge.h` 替换 player.c 内的 miniaudio 调用，接口层一致（§15.2）；
- 跨平台边界说明见 §15（Linux ALSA/Pulse/PipeWire、Windows WASAPI、macOS CoreAudio）。

### 9.8 ALAC（M4A 内无损） —— **自研 Zig**（已实现，2026-08-16）；`alac.c` 兜底

> 决策（2026-08-15）：ALAC 与 FLAC/APE 同类（无损、可 bit-exact 校验、有参考实现），
> 升级为自研目标（§3.7）。

- 算法：帧内自适应线性预测（LPC 系数逐样本自适应更新）+ Rice 风格残差熵编码（自适应
  history / 零块压缩 / escape 路径 / sign_modifier）+ 多声道 element 组合（SCE/CPE/LFE，
  按 FFmpeg `ff_alac_channel_layout_offsets` 布局）+ 立体声去相关；~1800 行；
- 容器：`fmt/m4a.zig` 一并自研（ISO-BMFF：ftyp/moov→trak→mdia→minf→stbl 的 stsd/stts/
  stsc/stco/co64/stsz 表解析 + hdlr 'soun' 音频轨判定 + stsd 'alac' 36 字节 magic cookie
  提取 + 三表合成线性 sample 表 + stts 展开帧偏移支撑整帧 seek），~700 行；
- 输出契约（对齐 FFmpeg alac 解码器）：sample_size ≤ 16 → 16-bit 输出；20/24/32 →
  32-bit 输出（左移 32-sample_size）；
- **验证闭环**：Apple 参考 `alac.c`（Apache-2.0，作对照不引入运行时）与 FFmpeg alac.c
  逐位复刻（lpc_prediction 指针递增语义、rice_decompress、decorrelate_stereo）；黄金文件
  （mono/stereo/5.1 × 16bit + mono 24bit）经 `alac_dump` 与 ffmpeg s16le/s32le 输出
  逐字节比对全 bit-exact（§17.2）；
- 兜底：非 ALAC 音频轨（如 AAC）→ `error.UnsupportedFormat` 回退 FFmpeg 主后端；
  `alac.c`（单文件 C，Apache-2.0）编译进内核，接口隔离无缝切换。

### 9.9 WavPack（.wv） —— **已实现并通过 bit-exact 对照验收**

> 决策（2026-08-15）：WavPack 支持无损模式，可 bit-exact 校验，升级为自研目标（§3.7）。
>
> 状态（2026-08-17）：**已实现并通过 bit-exact 对照验收**（§17.2），`probe.formats.wv` 已开启接管。

- 容器：`wvpk` 头 + metadata 遍历自研（DECTERMS/DECWEIGHTS/DECSAMPLES/ENTROPY/HYBRID/
  INT32INFO/FLOATINFO/DATA/EXTRABITS/CHANINFO，`fmt/wv/lib.zig`）；
- 解码：LSB-first 熵解码（零块压缩 + unary 区间 + median 自适应 + 混合模式逐位逼近）+
  去相关 terms（t>8 二阶预测 / t≤8 环形缓冲 / t=-1/-2/-3 自预测交叉项）+ joint 反变换 +
  s16 u32 模乘权重快速路径 + float 重建；混合模式/浮点/多声道包（INITIAL..FINAL 块流）；
- 输出契约：s16 → 16-bit、s32 → 32-bit 顶对齐、float → 32-bit IEEE，交错小端，`Info.bits_per_sample`=16/32；
- **验证闭环**：`wv_dump` 对照工具 + 4 黄金样本（s16 mono/stereo、s32 stereo、f32 stereo）经
  ffmpeg 编码，与 `ffmpeg -f s16le/s32le/f32le` 输出**逐字节比对全 bit-exact**（§17.2）；
- 范围：混合有损 `.wvc` 修正文件、DSD 调制为加分项不做承诺（DSD 在 open 判
  `error.UnsupportedFormat` 回退 FFmpeg 主后端，§8.3）；
- 兜底：vendored `libwavpack`（BSD-3-Clause，源码入库）`WavpackUnpackSamples`。

### 9.10 APE（Monkey's Audio） —— **已实现并通过 bit-exact 对照验收**

> 决策（2026-08-15）：APE 能力**自研实现**，不再依赖 Monkey's Audio 官方 SDK，
> 彻底消除 §20 的许可证阻塞项，符合 P2"能自研就自研"。无损解码可 **bit-exact 校验**，
> 验证闭环优于有损编解码。
>
> 状态（2026-08-17）：**已实现并通过 bit-exact 对照验收**（§17.2），
> `probe.formats.ape` 已开启接管；样本覆盖版本 3.80 / 3.88 / 3.89 / 3.91 / 3.92 /
> 3.94 / 3.99（normal / extra-high 压缩级别，16-bit 立体声 + 24-bit 立体声）。

**算法构成（自研实现，模块结构 `kernel/fmt/ape/`）**：

| 模块 | 说明 | 参考对照 |
|---|---|---|
| `container.zig` | `MAC ` 魔数 + 描述符（v≥3980：descriptor/header/seektable/wavheader 布局；v<3980：紧凑头 + peak/seek + 内嵌 WAV 头在 seektable 之前）+ seektable 帧表 + bittable（<3810） | `libavformat/ape.c` |
| `rangecoder.zig` | 无乘法区间编码（low/range/help/buffer + 归一化）+ counts_3970/3980 固定概率表 + Rice（k/ksum 自适应）+ 版本化熵解码：decode_array_0000（<3860，GetBitContext 位流）/ ape_decode_value_3860 / _3900 / _3990（pivot 自适应 base）；stereo 3900-3929 含「normalize + ptr-1 回退 + 区间重开」怪癖对齐 | `libavcodec/apedec.c` |
| `predictor.zig` | 多预测器：filter_fast_3320（<3930 FAST）/ filter_3800（<3930 常规，d0..d4 派生 + A/B 系数自适应）/ predictor_update_3930（3930-3949）/ predictor_update_filter（≥3950 64-bit，interim_mode 双趟）；长滤波 long_filter_high_3800 / long_filter_ehigh_3830（HIGH/EXTRA_HIGH）；终级滤波 do_apply_filter（≥3930，版本 <3980 / ≥3980 两套自适应 + clip_int16 延迟历史） | `libavcodec/apedec.c` |
| `bitreader.zig` | GetBitContext 等价（MSB-first + unaryStop），供 <3900 位流路径 | `get_bits.h` / `unary.h` |
| `lib.zig` | 帧解码编排（bswap 帧缓冲 → 熵 → 滤波 → 预测 → 去相关 → 输出打包 + CRC）+ VTable + seek | `libavcodec/apedec.c` ape_decode_frame |

**验证闭环（bit-exact，全样本全绿，§17.2）**：

1. **黄金文件**：FFmpeg FATE 样本（`samples.ffmpeg.org/fate-suite/lossless-audio/`，
   入库 `samples/ape/`）——版本 3.80/3.88/3.89b1/3.91b1/3.92b2/3.94b1（c2000/c4000）、
   3.99（partial）、24-bit 3.99（NoLegacy-cut）；
2. **对照参考**：`ape_dump`（直连 `fmt/ape/lib.zig`）输出与系统 FFmpeg 9.0.1
   （与 `reference/FFmpeg` n9.0.1 同源）`-f s16le / -f s32le` 参考输出**逐字节比对全 bit-exact**；
3. **CRC 校验**：帧末回算 AV_CRC_32_IEEE_LE（反射表，对齐 av_crc）比对帧头 CRC，
   不匹配 → error.Corrupt（可定位损坏帧）；
4. **截断容错**：帧数据不足（截断文件 / 越界 seek）→ 保留已成功块输出、跳过 CRC、
   置 EOF（对齐 FFmpeg 对短包的「部分解码」行为）；
5. 上线：`probe.formats.ape = true`（APE 接管）；实现无需兜底（无外部依赖）。

**输出契约（对齐 FFmpeg，bit-exact 对照锚定）**：

- bps 8 → u8（`(decoded + 0x80) & 0xff`）；bps 16 → s16；bps 24 → s32（`decoded * 256U` 顶对齐）；
- 交错小端 PCM，`Info.bits_per_sample` = 8 / 16 / 32。

**范围与容错（§9.10 / §13.3）**：

- 仅 mono / stereo（FFmpeg 同限）、bps ∈ {8,16,24}、版本 3800-3990；
- 压缩级别须为 1000 的倍数且 ≤ 5000（< 3930 禁 insane）；
- 帧/位流越界、除零、CRC 不匹配 → error.Corrupt（不崩溃）；区间归一化数据耗尽置
  error 标志零填充推进（对齐 FFmpeg `ptr >= data_end`）；
- 预测器更新规则逐位复刻（u32/u64 回绕 + 算术右移 + 符号自适应全对齐），
  interim_mode 双趟（24-bit ≥3950）含帧间状态保持。

**风险控制（实现完成后的剩余项）**：

- 冷门版本（3.80 以前）不支持 → 明确 `UnsupportedFormat` 回退 FFmpeg 主后端；
- 无 FAST/INSANE 压缩级别样本（FATE 无 c1000/c5000 样本）——两条预测器路径
  （filter_fast_3320 / insane 终级滤波 order 1280）已按 FFmpeg 语义实现但未经
  bit-exact 样本锚定，后续如有对应样本再补充验收；
- 若自研质量不可控（极端情况），回退方案仍为 §3.3 的 vendored 路径——但**许可审查仍按 §20 独立完成**，
  自研成功后该回退不再需要。

### 9.11 DSD（.dsf / .dff / .dsd） —— 自研

- 容器：DSF（`DSD ` 头 + chunk 表）/ DFF（`FRM8`）自研（~150 行）；
- DSD→PCM：1-bit 流 → 抽取 + 低通（CIC/多级 IIR，~200 行）——**纯信号处理，自研可行**；
- 目标输出 44.1kHz 倍率 PCM（按声道数×倍率，常见 DSD64/128/256）；
- 无损收藏播放的"软 DSD"路径：不追求 bit-exact DoP，转 PCM 播放入耳可接受。

### 9.12 Vorbis（OGG 内） —— vendored `stb_vorbis`（裁决：ROI 低，不自研）

- 复用 `fmt/ogg.zig`；解码走 `stb_vorbis`（public domain，单文件）；
- **裁决结论（§3.7）**：Vorbis 为有损编解码、无 bit-exact 参考闭环，自研需 MDCT + 码本
  （矢量量化）+ Floor0/1 + 残差 + 声道耦合全链 ≈4000 行，且已是 Opus 替代的黄昏格式 →
  **不自研**，vendored PD 单文件（零许可风险、零维护成本）；
- 若未来 Vorbis 使用率显著回升，再按 §3.3 规则重新评估。
- **标签（2026-08-31，已实现）**：`fmt/vorbis/lib.zig` open 后调
  `stb_vorbis_get_comment` 取 comment_list（`"KEY=value"` C 字符串数组），映射
  TITLE/ARTIST/ALBUM/DATE/GENRE/COMMENT/DESCRIPTION → 6 标准字段（首字段优先，
  大小写不敏感），全部条目（含 encoder/REPLAYGAIN_* 等非标准键）入 `tags`；
  生命周期随 `VorbisCtx` deinit 释放（本地 `freeMeta`）。验证：ffmpeg 带标签
  样本 6 字段 + 7 条 tags 全部提取。**缺口**：replaygain 数值映射（键保留在
  tags）、PICTURE 图（Vorbis 无标准图片注释）。

### 9.13 AMR（.amr / 3GP 音频） —— 自研容器 + vendored OpenCORE AMR（Apache-2.0，Phase F）

- `#!AMR` 头 + 帧重同步自研（~100 行）；解码走 OpenCORE AMR-NB（Apache-2.0）；
- 低频格式，仅 Phase F 按需开启。
- **Seek（2026-08-31，已实现）**：`fmt/amr.zig` `seekMsImpl` 帧头顺序跳过
  （读 1 字节 ftype → 按 `frame_sizes[ftype]` seek 载荷，不解码），并按帧数回填
  `samples_done`（160/帧 @8k）；OpenCORE 解码器 `Decoder_Interface_exit/init` 重置。
  验证：51.5s 样本 5 位置（0/1/10/25/45s）`position_ms` 精确到目标，输出 vs
  `ffmpeg -ss` corr 0.9991（±1 LSB，AMR 有损 + 重置状态）。
- **AMR-WB 误判修正（2026-08-31）**：`probe.zig` 原 `#!AMR` 前缀匹配会把
  `#!AMR-WB\n` 误判为 `.amr`，open 全等校验报 `Corrupt` 而非回退。已改：probe
  `#!AMR\n` 全等或排除 `#!AMR-WB` → 非 AMR-NB 返回 UnsupportedFormat 交 FFmpeg。
- **C 源码 UB 修复（2026-08-31）**：vendored OpenCORE 有符号负左移
  （`lsp_az.c:198/209/215/219`，如 `-x << 10`）在 zig Debug 下触发 UB 检测 panic
  （ReleaseFast 亦属未定义行为）。处理：`lsp_az.c` 三处改等价乘法（`-x*1024`、
  `t0*4`、`*lsp*1024`），并在 `build.zig` 对 vendored C（stb_vorbis + OpenCORE）
  编译 flags 统一加 `-fno-sanitize=undefined`。验证：51.5s 样本完整解码
  （2493 帧/398880 样本）不再 panic。

### 9.14 AC-3 / E-AC-3 / TrueHD（Dolby 家族） —— **自研完成**（2026-08-31 接管）

> 决策（2026-08-30~31）：Dolby 数字音频家族（AC-3/E-AC-3/TrueHD-MLP）**完全自研**，
> 对照 FFmpeg `ac3dec_float`/`mlpdec` 逐位/相关验收。Atmos JOC 因 Dolby 专有格式
> 法律风险（无公开文档、专利风险、FFmpeg 亦跳过）**放弃逆向**，保持 ffmpeg 一致的
> 7.1 输出。

- **AC-3 / E-AC-3（`fmt/ac3/`）**：
  - `header.zig` —— 帧头/bsi（acmod、lfe、bsid、E-AC-3 strmtyp/frmsiz 优先级
    `(x+1)<<1`、dependent substream 解析）、`mantissa.zig`（bap 分档反量化 + AHT
    + 耦合 calcTransformCoeffsCpl + removeDithering）、`downmix.zig`（重矩阵 + 下混）、
    `md5.zig`（libavutil AVLFG 复刻：64 状态加性 LFG + MD5 填充）、`kbdwin.zig`。
  - **关键修复记录**：mdct_exp_256 表重新生成（含 1/8388608 缩放 bug）；
    dynamic_range_tab 初始化（`2^v × ((i&0x1F)|0x20)`，原漏 mantissa 且错除 4）；
    DithLcg → AVLFG（64 状态，对齐 libavutil）；EAC3 frame_size 优先级；
    open() 预读回退、EOF 死循环、输出转换去 ×8388608、window_256 f64→f32。
  - **mono E-AC-3 静音修复（2026-08-31）**：根因 `decodeAudioBlock` 中 E-AC-3
    的 `cpl_strategy_exists==0`（mono 无耦合）时错误 `return 1` → 全块静音。
    对照 FFmpeg `decode_audio_block`（`else if (!s->eac3)` 分支只对 AC-3 生效），
    改为 E-AC-3 无策略时不做任何操作。修复后 mono E-AC-3 corr **1.0**。
  - **Seek（2026-08-31）**：帧级跳过（`decodeFrame` 逐帧重解，目标帧 = ms×rate/1536）。
    关键修复：跳过帧的 out 须丢弃（off-by-one，否则位置错 1 帧）。验证：stereo
    AC-3/E-AC-3 内部一致性 100%（seek1000 == 从头 31 帧后）、vs `ffmpeg -ss`
    corr 1.0；mono E-AC-3 3 位置 corr 1.0。
- **MLP / TrueHD（`fmt/mlp/`）**：MLP(0xbb)/TrueHD(0xba) 无损全链路；每帧实际输出
  样本 = `blockpos`（40，≠ access_unit_size_pow2 64）；Atmos 标志（第 4 子流）检测
  但不解码。**验证**：fate TrueHD Atmos 样本 `atmos.thd` **bit-exact 40960/40960**。
  **Seek（2026-08-31）**：positionMs 累计实际输出样本 + seek 回开头重解跳过 +
  positionMs 校准 + **seek 后清 out_len=0**（根因：跳过最后一帧 out_len 残留导致
  readImpl 重复复制错位 1 帧）；seek 内部一致性 100%（seek50ms == 从头到 50ms）。
- 接线：`probe.zig` `.ac3`（`\x0b\x77`）/ `.truehd`（`\xf8\x72\x6f\xba`）已接入。

---

## 10. 采样转换：格式转换 / 下混 / 重采样

全部自研 Zig（`kernel/pcm/*`），拆三个原语，各自可旁路（passthrough 时开销≈0）：

### 10.1 `convert.zig`：采样格式转换

- `AudioDecoder` 原生样本（s16/s24/s32/f32/f64，交错）→ float32 交错；
- 位深提升 + 归一化（s16 → /32768，s24 → /8388608，s32 → /2³¹），逐样本，无滤波器；
- 始终执行（解码器输出非 float），成本 memcpy 级。

### 10.2 `downmix.zig`：声道下混

- 输入声道 > 目标声道时执行，否则直通；
- ITU-R BS.775 系数（对齐现状 fft 的下混）：5.1 → `L=FL+0.707·C+0.707·BL`，`R=FR+0.707·C+0.707·BR`，
  LFE 不入下混；未知布局回退等权。

### 10.3 `resampler.zig`：采样率转换（SRC）

- 旁路：`passthrough`（桌面默认）且输出采样率 == 源采样率 → 零成本直通；
  仅强制 48k（Web 兼容）或 DSP 要求统一采样率时执行；
- 自研 windowed-sinc（Kaiser 窗）多相 FIR：`2^n` 相位 + 链式 2× 升采样；
  目标阻带 ~100dB / 通带波动 <0.01dB（对齐 swr 默认质量）；极大倍率退化线性插值兜底；
- **备选**：若质量/性能不达标，vendored `libsamplerate`（BSD，单库源码）——但判定为大概率不需要；
- 基准对齐现状 `swr_convert`（44.1k↔48k / 44.1k→96k），要求自研 ≤ 2× swr 时间。

---

## 11. 编码器与 OGG 封装（可选模块）

> 桌面播放路径 `skip_encoder=true`（不编码），本模块仅 Web 兼容 / CLI 批量。

### 11.1 `encode/opus_encoder.zig`

- vendored `libopus`：`opus_encoder_create` / `opus_encode_float` / `opus_encoder_destroy`；
- 配置对齐现状：48kHz 固定、`application=audio`、bitrate 按 QualityLevel 映射、frame=20ms（960 @48k）。

### 11.2 `encode/ogg_muxer.zig`（自研）

- RFC 3533 + RFC 7845：OggS 页头 / lacing / 页 CRC（非反射 CRC-32，自写表）/ OpusHead 头页 /
  OpusTags 元数据页；granule = `3840·(n-1) + pre-skip` 语义；
- 输出保持 `OutputCallback`（`audio_engine.h`）签名，UDS/stdout 路径不变。

---

## 12. 时长 / 定位 / Seek 语义

### 12.1 统一时长模型

```
Info.duration_us + Info.duration_known ∈ { exact, estimate, unknown }
```

| 格式 | 时长来源 | 精度 |
|---|---|---|
| FLAC | STREAMINFO `total_samples` | exact |
| WAV/AIFF | data 字节数 / 字节率 | exact |
| OGG/Opus | 尾页 granule（首帧先 estimate，后台扫描回填） | exact（回填后） |
| OGG/Vorbis | 尾页 granule | exact（回填后） |
| M4A（AAC / ALAC） | `mvhd` duration | exact |
| WavPack | 头 `total_samples` | exact |
| DSD（DSF/DFF） | 头 `sample_count` / `marker` 总数 | exact |
| APE | 头 `total_frames` × 帧长 | exact |
| MP3 CBR | 文件大小 / 比特率 | exact（Xing/Info 头存在）或 estimate |
| MP3 VBR | XING/Info 头（存在时） | exact |
| MP3 VBR（无头） / ADTS | 首遍全扫建索引 | 首遍后 exact |
| AC-3 / E-AC-3 / TrueHD / AMR | open 时未知（帧同步流，无容器索引） | unknown |

### 12.2 位置跟踪

- `Decoder.position_ms()`（累计 read 输出样本）替代现状 `resampler_get_output_samples`；
- `start_offset_ms`（CUE）：`seek_ms(offset)` 后计数，语义一致。

### 12.3 各格式 seek 实现（已实现）

- **MP3（§9.4）**：按总帧数（Xing 精确 / 首帧估算）比例估算字节偏移，再帧同步扫描定位最近帧边界；
  XING/Info 头 → 直接利用其帧数，免全扫，时长精确；bit reservoir 依赖帧自动跳过到最近可独立解码帧
  （minimp3 同款语义）；批量模式（不 seek）无额外开销。
- **Opus（§9.2，2026-08-31）**：`Demux.seekToGranule` 逐页扫 granule（含 pre-skip）→ 字节定位目标页 →
  清重组状态 → 解码丢弃到目标样本；**pre-skip 只在从头解码时消耗**（seek 不重置）。验证 5 位置
  corr 1.0。
- **AC-3 / E-AC-3（§9.14，2026-08-31）**：目标帧 = ms×rate/1536 → 从头逐帧 `decodeFrame` 跳过；
  跳过帧 out 丢弃（off-by-one 修复）。内部一致性 100%。
- **AMR（§9.13，2026-08-31）**：帧头顺序跳过（读 ftype → seek 载荷，不解码）+ OpenCORE 解码器
  `exit/init` 重置。position 精确到目标。
- **TrueHD / MLP（§9.14，2026-08-31）**：回开头重解跳过 + positionMs 校准 + seek 后清 out_len=0；
  内部一致性 100%（seek50ms == 从头到 50ms）。

### 12.4 seek 语义约束

- 允许"近似"（MP3 帧对齐 / Opus granule 对齐），仅需 ≥ 现状精度
  （现状 `AVSEEK_FLAG_BACKWARD` 同为帧级对齐）；
- 桌面实时 seek 走 miniaudio（WAV 即时），解码器 seek 仅用于 CLI/Web 兼容/CUE 起始偏移。

---

## 13. 中断、错误与容错

### 13.1 中断（替代 AVIOInterruptCB）

- `Reader.abort()` 置原子标志 → 所有 `read/seek/peek` 返回 `error.Aborted`；
- 引擎 SIGTERM / stop 命令 → `engine.zig` 调 `abort()`（对齐现状 `decoder_interrupt` + `pipeline_signal_shutdown`）；
- 本地文件读取不阻塞，中断响应为"下一帧边界"，延迟 < 一帧时长。

### 13.2 错误模型（Zig error set）

```zig
pub const Error = error{
    UnsupportedFormat,  // 探测失败/格式不支持
    OpenFailed,
    Corrupt,            // 容器/帧损坏
    DecodeFailed,
    Aborted,
    SeekFailed,
    OutOfMemory,
    IoError,
};
```

- 模块内坏帧/坏包**跳过并计数**（连续 ~256 次放弃，对齐现状容错），不中断整体；
- FFI 边界把 Zig error 映射为 `{"type":"error","message":"..."}` → Dart `EngineError`（协议不变）。

### 13.3 安全

- Debug/Safe 模式下数组越界/整数溢出由编译器检查（处理不可信媒体输入的核心收益）；
- 解析器所有长度字段校验 `<= 输入大小`，循环有界（页数/帧数上限），防 zip-bomb/畸形文件 DoS；
- 变长条目 clamp 语义：`smpl`/`cue ` 的条目计数 clamp 到 chunk 实际承载（`min(count, size/24)`），
  文件截断时保留已解析条目、不越界读（§9.1）；RIFX 大端按容器字节序读取。
- FLAC（§9.3）：ID3v2 前置标签按 synchsafe 28 位计算 size 后**有界跳过**（超窗时 probe seek
  判定后再跳，位置不消耗）；未知元数据块类型（7..126 保留 + 127 INVALID）一律跳过不拒播
  （FFmpeg flacdec default 分支同款容错）；坏帧触发**重同步**（跳过损坏帧、复用同步码扫描
  定位下一合法帧，连续放弃计数，对齐现状容错不中断整体）；REPLAYGAIN 畸形值（非数值 /
  越界）保持 null 不崩溃。

---

## 14. DSP 移植与 libfft.so（保持 Dart ABI）

- `equalizer/loudness/limiter/fft` 四个 DSP 模块把现状 C 实现**逐函数移植到 Zig**
  （现有 C 共 ~1200 行，语义对照移植，配套测试直接复用 `tests/test_equalizer.c` 等黄金断言）；
- 移植后经 `kernel_bridge.h`（`zk_dsp_*`）被 C 壳 `pipeline.c` 调用；现状 `equalizer.c/loudness.c/
  limiter.c` 在移植完成前保留为过渡实现（§4.1），移植完成后删除；
- `libfft.so` 的 Dart ABI 必须保持不变：`fft_create/fft_set_enabled/fft_process_multi/
  fft_get_spectrum_norm_stereo/...` 以 `export fn ... callconv(.C)` 从 `kernel/dsp/fft_abi.zig` 导出，
  `fft_bindings.dart` **零改动**；移植期 `src/fft.c` 临时保留（`fft_abi.zig` 可先 `@cImport` 复用），
  再逐模块替换，降低一次性移植风险。

---

## 15. 播放器输出层（跨平台难点）

现状 `player.c` 用 miniaudio 播放引擎落盘的 float32 WAV（全解码、即时 seek）。Zig 方案
（**自研目标**，§3.7 / §9.7）：

### 15.1 目标：`kernel/device.zig` 自研设备抽象

```
kernel/device.zig                    # 跨平台抽象 + 后端选择
├── backend.zig                      # 后端注册/探测（编译期 + 运行期能力协商）
├── backend_linux_alsa.zig           # ALSA（或经 dlopen 动态加载，零头依赖）
├── backend_linux_pulse.zig          # PulseAudio/PipeWire（经 dlopen，零头依赖）
├── backend_windows_wasapi.zig       # WASAPI（Zig 自带 mingw 头，交叉最顺）
└── backend_macos_coreaudio.zig      # CoreAudio（需 macOS SDK，macOS CI job 构建）
```

- 职责对齐现状 miniaudio 用法：打开默认设备 → 播放 float32 PCM（全解码缓冲，即时 seek）
  → 位置按音频帧驱动（50ms 事件）→ 音量/暂停/停止；
- 播放语义保持不变：**仍是播放引擎落盘的 float32 WAV**（`stream.wav`），device 层只做"读 PCM 出声"；
- 后端按 `build.zig` target 编译期选择，能力协商（设备枚举/采样率/声道）做运行期探测；
- **增量落地**：先实现 Linux（ALSA 或 Pulse 动态加载），再 Windows WASAPI，最后 macOS CoreAudio——
  每后端独立验收（真机出声 + 位置事件正确）。

### 15.2 过渡期兜底：miniaudio

- 现状 `include/miniaudio.h` 已 vendored（v0.11.25，MIT-0/PD），`src/player.c:22-23` 是**唯一**
  `MINIAUDIO_IMPLEMENTATION` 实例化点（C 壳保留后维持不变，**不新建 `c/miniaudio.c`**）；
- 自研 device 未完成的后端/平台，player.c 继续使用 miniaudio；`device.zig` 完成后，
  对应后端经 `kernel_bridge.h` 替换 player.c 内的 miniaudio 调用，对上层零感知；
- **移除路径**：三平台后端全部验收后，删除 `include/miniaudio.h` 与 player.c 内的
  `MINIAUDIO_IMPLEMENTATION` 分支——输出层 100% Zig/自研（P2 完全达成）。

### 15.3 跨平台边界（P1 原则的落地）

| 平台 | 构建期头依赖 | 说明 |
|---|---|---|
| Linux | **无**（ALSA/Pulse/PipeWire 全经 dlopen 动态加载） | 零头依赖，从任何宿主可交叉编译含输出层的全量产物 |
| Windows | **无**（Zig `x86_64-windows-gnu` 自带 mingw WASAPI/winmm 头） | 交叉编译最顺 |
| macOS | 需 macOS SDK（AudioToolbox/CoreAudio 头） | 全量构建须在 macOS 上执行；Linux 宿主只做内核/其他平台交叉编译 |

> 结论：**内核（解码/DSP/编码/FFI）完全平台无关且可从任意宿主交叉编译**；
> 输出层收敛为"每平台一个 `backend_*.zig`"，是唯一依赖系统 SDK 的边界，按上表分派 CI，
> 完全符合 P1「平台差异收敛到边界层」。

### 15.4 验收标准（每后端）

1. 真机出声（float32 PCM 播放 + 音量 + 暂停/恢复 + 停止）；
2. 位置事件按音频帧推进（50ms 语义，对齐 §16.1 事件协议）；
3. seek 即时（WAV 全解码缓冲，游标直接跳帧）；
4. 无声卡环境优雅降级（`error.NoDevice` → 引擎 `{"type":"error"}`，不崩溃）；

---

## 16. FFI 边界与 CLI（C 壳保留，Zig 经桥接接入）

> 架构调整（2026-08-16 用户决策）：**调用部分保留在 C**。`mediaengine_lib.c` / `main.c` 不作重写，
> Zig 内核以静态形式经 `kernel_bridge.h`（`zk_*` C ABI）被 C 壳调用，Dart / Web 契约零改动。

### 16.1 桥接 API：`include/kernel_bridge.h`（新增）+ `kernel/kernel.zig`（导出）

```c
/* include/kernel_bridge.h —— C 壳 → Zig 内核的唯一入口（解码 / DSP 服务） */
typedef struct ZkDecoder ZkDecoder;
typedef struct ZkInfo {
    int sample_rate, channels, bits_per_sample;
    long long duration_us; int duration_known;   /* exact/estimate/unknown */
    const char *codec_name, *format_name;
    /* 标签元数据（缺失为 NULL；生命周期与 ZkDecoder 一致，C 侧只读不释放） */
    const char *title, *artist, *album, *date, *genre, *comment;
} ZkInfo;

ZkDecoder *zk_decoder_open(const char *path, ZkInfo *info, char *errbuf, int errbuf_size);
size_t     zk_decoder_read(ZkDecoder *d, float *out, size_t max_frames, int *out_channels);
int        zk_decoder_seek_ms(ZkDecoder *d, long long ms);
long long  zk_decoder_position_ms(ZkDecoder *d);
void       zk_decoder_close(ZkDecoder *d);

/* DSP（Zig 移植；运行期可调 EQ / tempo 等） */
typedef struct ZkDspChain ZkDspChain;
ZkDspChain *zk_dsp_create(const ZkDspConfig *cfg);
void        zk_dsp_process(ZkDspChain *d, float *buf, size_t frames, int channels);
void        zk_dsp_set_eq(ZkDspChain *d, const float gains[10], float preamp_db);
void        zk_dsp_set_tempo(ZkDspChain *d, float speed, float pitch);
void        zk_dsp_destroy(ZkDspChain *d);
```

- `kernel/kernel.zig` 以 `export fn zk_* ... callconv(.C)` 实现上表符号，内部走 Zig 内核管线
  （`engine.zig` → `decoder.zig` 工厂 → `pcm/*` → `dsp/*`）；错误经 errbuf / 返回值区分；
- `ZkInfo.codec_name` 透传各格式实际编码器名（WAV 侧新增：`gsm_ms`/`gsm`、`mace3`/`mace6`、
  `adpcm_ima_dk4`/`adpcm_ima_dk3`/`adpcm_ima_xbox`、`adpcm_sanyo`、`xan_dpcm`、
  `adpcm_zork`、`adpcm_swf`、`adpcm_g722`、`adpcm_g726`、`pcm_f16le`/`pcm_f16be`）；
  `decoder.Info` 另含 WAV `smpl`/`cue `
  采样循环点 `loops` / `cue_points`（§9.1）与 FLAC VORBIS_COMMENT 标签 `metadata` /
  全量标签条目 `metadata.tags` / REPLAYGAIN 增益 `replay_gain` / CUESHEET 提示点
  `cue_points` / PICTURE 封面图 `pictures`（§9.3），当前为内核侧只读，
  C ABI 需要时再扩展 `ZkInfo` 导出（不破坏既有字段布局）；
- 线程模型（修订 2026-09-09，取代"内核本身不持线程，仅被 C 壳调用"）：**Zig 内核自持调度
  线程**——Master 事件线程 + Pool worker 由 `kernel_init` 创建、`kernel_shutdown` join（不变量
  与设计见 `docs/engine-master-pool-design.md` §2.1/§3.1/§6）。`mediaengine_lib.c` 引擎线程与
  事件/命令 FIFO 原样保留——它驱动的 `zk_*` **sync 直通**退为回归/调试基线（该文档 §7）；
  生产播放迁池内流式会话（该文档 §6.3）。`fmt/*` 与 `Decoder` 仍保持纯 Sync 语义（无内部
  线程、无 async 状态机），由 Pool worker 或 sync 直通调用线程驱动。
- `EngineConfig` 由 C 壳解析（`audio_engine.h`），桥接层只接收已映射的标量/结构参数，无需
  跨语言传 JSON 结构体。

### 16.2 FFI 库：`mediaengine_lib.c`（保留，改动最小）

- `archoera_mediaengine_*` 6 个导出符号（`create/command/poll_event/session_dir/is_done/destroy`）
  **原样保留**，Dart `engine_bindings.dart` / `audio_engine_process.dart` **零改动**；
- `create` 内部：解析 `EngineConfig` → 构造 `ZkDspChain`（如启用）→ 引擎线程内 `zk_decoder_open` +
  `zk_decoder_read` 循环 → DSP → 落盘 `stream.wav`（player 模式）/ `stream.pcm`（FFT 拉模式）
  （此落盘描述为**文件模式**基线；内存播放模式下解码产物驻留进程内内存块列表，频谱经
  `archoera_mediaengine_pcm_window` FFI 拉取，见 `docs/audio-memory-playback.md`）；
- 默认构建（`-Duse-ffmpeg` 默认开）时：`zk_decoder_open` 返回不可恢复错误（`UnsupportedFormat` /
  持续失败）→ C 壳切 `decoder_ffmpeg.c` 后端（默认主，§8.3），事件带 `backend` 字段；已接管格式
  优先 Zig，失败回退 FFmpeg；
- Web/CLI 路径（`main.c` + UDS/stdout）保持现状，仅解码来源切换为桥接（含 FFmpeg 主后端）。

### 16.3 CLI：`main.c`（保留）

- 保留全部现状 CLI 参数与 UDS 语义（`--interactive/--control-uds/--pcm-uds/--stream-uds/
  --player-file/--eq/--tempo...`）；
- 解码来源切到 `zk_*` 桥接；SIGTERM → 桥接 `abort` + 优雅退出，UDS 生命周期与现状一致；
- 不再需要 `cli.zig` / `std.getopts`（原设计作为 `main.c` 替代品，2026-08-16 架构调整后取消）。

### 16.4 与 `engine-event-push-plan.md` 的衔接

> `engine-event-push-plan.md` 第一步「源头降频」（`set_event_interval` + position 合并）已落地；
> 第二步「去轮询推送」（native port 唤醒替代 Dart 50ms 轮询）**尚未实施**。本次重构（C 壳保留、
> Zig 内核接管解码/DSP）不改动事件 FIFO 与轮询契约（P5 不变量），第二步可在重构完成、输出层
> 自研（§15 `device.zig`）期间一并评估——届时事件由设备音频帧驱动，天然具备推送能力。

---

## 17. 测试与验证

### 17.1 单元测试（`zig build test`）

- `tests/` 每格式黄金文件（MP3/FLAC/OGG-OPUS/WAV/M4A **+ T1：ALAC/WavPack/DSD/AIFF/Vorbis** 小样本）
  + 输出 PCM **MD5/SHA256 校验**；
- `probe.zig` 全表 + 混淆用例（ADTS vs MP3）；每个格式开关各编译一遍确认裁剪正确（`-Dape=false` 时 probe 判 unsupported）；
- `pcm/*` 逐样本校验 + 误差界；`ogg_muxer.zig` 输出可被 `opusinfo` / 系统播放器打开；
- DSP 移植：复用现状 `tests/test_equalizer.c` 等的黄金断言（移植为 Zig test）。

### 17.2 一致性对比（迁移护栏，对齐旧方案 §13.2）

- 默认构建即含 FFmpeg 主后端（`-Duse-ffmpeg` 默认开）——**FFmpeg 输出是天然基准**，无需单独保留
  旧 C 引擎产物；Zig 每格式实现与 FFmpeg 输出对照：
- 同一输入分别经 Zig 内核与 FFmpeg 后端转码 float32 WAV：无 DSP 路径 `MAX_DIFF < 1e-4`（float）
  或逐样本 bit-exact（int，无损格式）；有 DSP 路径用响度/频谱统计断言；
- 参考实现：`reference/FFmpeg`（2026-08-16 克隆，n9.0.1，与系统 FFmpeg 9 同源，含全部解码器
  `.c` 源码与头文件，见 §2.1）；
- 接管判定：某格式 Zig 实现对照全绿（bit-exact/误差界）即开启对应格式开关（`-Dzig-<fmt>=true`）
  正式接管；全部 T0/T1 接管后可 `-Dzig-main=true` 升主（默认仍 FFmpeg，§8.3）。
- **FLAC 对照验收（2026-08-16，已完成）**：`kernel/flac_dump.zig` 导出 PCM 与
  `ffmpeg -i <x.flac> -f s16le/s32le` 参考输出逐字节比对，全样本 bit-exact：

  | 样本 | 规格 | 参考格式 | 结果 |
  |---|---|---|---|
  | t16 / t16m | 16bit 正弦 立体声/单声道（flac 默认级别） | s16le | ✓ |
  | t24 | 24bit 正弦 立体声 | s32le | ✓ |
  | t32 | 32bit 正弦 单声道 | s32le | ✓ |
  | n16 / n24 / n8 | 白/粉/棕噪声，`flac -8`（LPC/fixed 路径） | s16le/s32le | ✓ |
  | ff16 / ff32 | **ffmpeg 编码器直出**（`-c:a flac`，s16@48k / s32 白噪声） | s16le/s32le | ✓ |

  单测 `zig build test --summary all`：113/113 全绿（含 CRC、帧头、残差、子帧、去相关、
  seektable/无表 seek、损坏帧 Corrupt 判定等集成用例）。

  FLAC 元数据扩展（2026-08-16）：VORBIS_COMMENT 标签 + CUESHEET 提示点 + PICTURE 封面图 +
  FFmpeg 对齐容错（ID3v2 前置 / 未知块跳过 / 坏帧重同步 / 全量标签 / REPLAYGAIN），对照/验收如下：

  | 样本 | 规格 | 结果 |
  |---|---|---|
  | flac_meta | VORBIS_COMMENT 标签（title/artist/album/date/genre/comment，COMMENT 与 DESCRIPTION 同义；大小写不敏感/首字段优先/未知键忽略/字段越界容错，单字段限长 4KB） | ✓ |
  | flac_cuesheet | CUESHEET 提示点（track/index offset → cue_points，条目数 clamp、头部越界容错） | ✓ |
  | flac_picture | PICTURE 封面图（type/mime/desc/宽高/色深/数据 → pictures；data 限长 64MiB、字段截断放弃该图且块对齐不破坏后续块） | ✓ |
  | flac_tags | 全量标签条目（TRACKNUMBER/ALBUMARTIST/REPLAYGAIN_*/encoder 等非标准键 → Metadata.tags，key 原样大小写、value 已 trim、重复键全保留，对齐 FFmpeg av_dict） | ✓ |
  | flac_replaygain | REPLAYGAIN_TRACK/ALBUM_GAIN（0.001dB 单位）与 _PEAK（0.00001 单位）→ Info.replay_gain；畸形值保持 null | ✓ |
  | flac_id3v2 | ID3v2 前置标签跳过（probe 窗口内/窗口外 seek 判定 + parse 跳头，位置不消耗；ffmpeg `-id3v2_version 3` 样本 bit-exact 解码） | ✓ |
  | flac_unknown_block | 元数据块未定义值（7..126 / 127 INVALID）→ **跳过**（FFmpeg default 分支 avio_skip 同款，块对齐不破坏后续）；仍无 STREAMINFO → Corrupt | ✓ |
  | flac_resync | 坏帧重同步：多帧中一帧 CRC-16 损坏 → 跳过坏帧、后续帧正常输出（不中断整体）；单帧全坏无产出 → Corrupt 透出 | ✓ |

  新增 6 个单测（未知块跳过、ID3v2 前置、tags 全量 + REPLAYGAIN、REPLAYGAIN 畸形容错、
  坏帧重同步、probe ID3→FLAC 识别），`zig build test --summary all` **185/185 全绿**。

  真实文件交叉核对：`ffmpeg` 编码带 ID3v2 前置 + VORBIS_COMMENT（含 TRACKNUMBER/
  REPLAYGAIN_*）标签的样本（`flac_dump` 现兼把元数据/全量标签/REPLAYGAIN/提示点/封面摘要
  打印到 stderr，stdout 仍为纯 PCM），与 `metaflac --list` 逐项比对 —— 全部 6 条标签、
  `REPLAYGAIN_TRACK_GAIN=-6.35 dB`（→ -6.350 dB / 99902 peak）一致，且 PCM 与 ffmpeg
  参考输出 bit-exact。
- **WAV 对照验收（2026-08-16，已完成）**：`flac_dump` 导出与 ffmpeg 参考逐字节比对，全样本
  bit-exact：

  | 样本 | 规格 | 参考格式 | 结果 |
  |---|---|---|---|
  | ws16 / ws24 / ws32 | PCM s16le/s24le/s32le（44.1k/48k） | s16le/s24le/s32le | ✓ |
  | wu8 | PCM u8 单声道 | u8 | ✓ |
  | wf32 / wf64 | IEEE float f32le/f64le 立体声 | f32le/f64le | ✓ |
  | wulaw / walaw | G.711 µ-law / a-law（解码输出 s16） | s16le | ✓ |
  | wadpcm_ms | MS ADPCM（tag 2，44.1k 三频正弦）单/双声道 | s16le | ✓ |
  | wadpcm_ima | IMA WAV ADPCM（tag 0x11）单/双声道 | s16le | ✓ |
  | wadpcm_ima_qt | AIFF-C "ima4"（IMA QT，跨块状态保持） | s16be | ✓ |
  | wadpcm_oki | OKI ADPCM（tag 0x10，连续流） | s16le | ✓ |
  | wadpcm_yamaha | Yamaha ADPCM（tag 0x20，连续流，stereo+seek） | s16le | ✓ |
  | wadpcm_ct | Creative CT（tag 0x200，连续流，step=511 初始化） | s16le | ✓ |
  | wadpcm_ms/ima 4ch/8ch | WAVEFORMATEXTENSIBLE 多声道（MS ≤6ch 可对照 ffmpeg，其余自验） | s16le | ✓ |
  | waiff | AIFF 大端 s16 立体声 | s16be | ✓ |
  | ww64 | Sony Wave64（probe 判定 bug 已修，§9.1） | s16le | ✓ |
  | wav_meta | WAV LIST-INFO + AIFF NAME/AUTH/ANNO 标签（title/artist/album/date/genre/comment，含截断容错） | — | ✓ |

  本次扩展（ADPCM 编解码器 + 多声道 + 标签元数据）新增 5 组 bit-exact 对照（oki / ct / yamaha /
  ms4ch / qt）全部 ✓；`zig build test --summary all` 139/139 全绿（含 IMA QT 跨块
  启发式、连续流递推、多声道块解码、LIST-INFO/AIFF 标签解析与截断保护等单测）。

  边界能力扩展（2026-08-16）：低复杂度编解码器 + 采样循环点 + 采样率上限，对照/验收如下：

  | 样本 | 规格 | 参考格式 | 结果 |
  |---|---|---|---|
  | wgsm_ms | GSM 06.10（tag 0x31，libgsm 编码，含 fact + seek 块对齐） | s16le | ✓ |
  | waiff_gsm | AIFF-C "GSM " 纯 GSM（MSB 位序） | s16be | ✓ |
  | wadpcm_dk4 | IMA DK4（tag 0x61）mono + stereo 块边界 | s16le | ✓ |
  | wmace3 / wmace6 | AIFF-C "MAC3"/"MAC6"（mono/stereo，含 seek flush 流式状态） | s16be | ✓ |
  | wsmpl_cue | WAV `smpl`/`cue ` 采样循环点/提示点解析（含计数超载 clamp、RIFX 大端） | — | ✓ |
  | wf16 / f24 | IEEE float16 放行（2 字节 half）；float24 拒绝 → FFmpeg 兜底 | f16le | ✓ |
  | wdxd_768k | 采样率上限放宽至 4 MHz（DXD 768k 通过 / 超限拒绝） | — | ✓ |

  此轮 MACE 无官方 encoder，黄金数据由零依赖 Python 参考实现（镜像 `reference/FFmpeg/libavcodec/mace.c`
  语义）生成、并经系统 FFmpeg 官方**解码器**交叉验证（4 用例 0 mismatch）后锚定；
  `zig build test --summary all` 171/171 全绿（含 GSM seek flush、MACE 状态保持、smpl/cue
  clamp 等单测）。

- **WAV wavdec/DPCM 系列收尾（2026-08-17，已完成）**：DK3 / XBOX / SANYO / XAN /
  ZORK / SWF / G.722 / G.726 黄金样本与 `ffmpeg -i <x.wav> -f s16le` 参考输出
  逐字节比对，全样本 bit-exact：

  | 样本 | 规格 | 参考格式 | 结果 |
  |---|---|---|---|
  | wadpcm_dk3 | IMA DK3（tag 0x62，sum/diff 立体声，22.05k） | s16le | ✓ |
  | wadpcm_xbox | XBOX ADPCM（tag 0x69，4B/通道头，48k 立体声） | s16le | ✓ |
  | wsanyo_m3 / wsanyo_s5 | SANYO LD-ADPCM（tag 0x125，3/5-bit，mono/stereo 8k） | s16le | ✓ |
  | wxan | XAN DPCM（tag 0x594A，块式 2B/通道头 + 交错样本，自验） | s16le | ✓ |
  | wzork | ZORK DPCM（tag 0x0011 + bits 8，连续流，stereo 8k） | s16le | ✓ |
  | wswf_mono / wswf_stereo | SWF ADPCM（tag 0x5346，块式 MSB 位流，nbits 2..5） | s16le | ✓ |
  | wg722 | G.722（tag 0x028F，每字节 2 帧，mono 16k） | s16le | ✓ |
  | wg726_2/3/4/5 | G.726（tag 0x0045，code_size 2/3/4/5，mono 8k） | s16le | ✓ |

  单测 `zig build test --summary all`：255/255 全绿（新增 G.722/G.726 黄金测试、
  decl 解析与 code_size 覆盖、G.726 立体声/越界拒绝等用例）。G.726 code_size 由
  byte_rate×8/sample_rate 推导（riffdec.c 254-256），位级游标保证 3/5 位等
  非整字节帧边界 bit-exact（`wav_dump` 复跑 5 样本与 FFmpeg 逐字节一致）；G.722/
  G.726 均为全 Zig 自研实现，无头文件/外部依赖。

- **ALAC/M4A 对照验收（2026-08-16，已完成）**：`kernel/alac_dump.zig` 导出 PCM（16bit 样本 →
  s16；24bit 样本 → s32 左移 8，对齐 FFmpeg）与 `ffmpeg -i <x.m4a> -f s16le/s32le` 参考
  输出逐字节比对，全样本 bit-exact：

  | 样本 | 规格 | 参考格式 | 结果 |
  |---|---|---|---|
  | s16_mono | 16bit 正弦+噪声 单声道 44.1k（aevalsrc 编码） | s16le | ✓ |
  | s16_stereo | 16bit 正弦+噪声 立体声 44.1k | s16le | ✓ |
  | s16_51 | 16bit 6 声道 5.1（amerge 编码，CPE/LFE element 路径） | s16le | ✓ |
  | s24_mono | 24bit 正弦+噪声 单声道 96k（32bit 输出左移 8） | s32le | ✓ |

  单测 `zig build test --summary all`：216/216 全绿（含 Rice 熵解码（零块/escape/sign
  修正）、LPC 预测与系数自适应（lpc_prediction 指针递增语义）、立体声去相关、extra bits、
  未压缩帧、多 chunk、整帧 seek、损坏帧 Corrupt、元素须覆盖全部声道且元素数不越界、
  音频轨但非 ALAC → UnsupportedFormat 回退等集成用例）。

  上线：`probe.formats.m4a = true`（ALAC 接管）；ADTS 裸流独立开关 `.aac = false` 不随 m4a
  误启，AAC 轨（实测 ffmpeg 编码 AAC m4a 样本）经 `fmt/m4a` 判 UnsupportedFormat 回退
  FFmpeg 主后端。

- **WavPack 对照验收（2026-08-17，已完成）**：`kernel/wv_dump.zig` 直连 `fmt/wv/lib.zig`
  导出 PCM，与 `ffmpeg -i <x.wv> -f s16le/s32le/f32le` 参考输出逐字节比对，全样本 bit-exact：

  | 样本 | 规格 | 参考格式 | 结果 |
  |---|---|---|---|
  | s16_mono | 16bit 正弦+噪声 单声道 44.1k 1.5s（ffmpeg wavpack 编码） | s16le | ✓ |
  | s16_stereo | 16bit 立体声 48k 1s（joint stereo + 负向/交叉 decorr 项路径） | s16le | ✓ |
  | s32_stereo | 32bit 立体声 44.1k 0.8s（`-af aformat=sample_fmts=s32`） | s32le | ✓ |
  | f32_stereo | 32bit float 立体声 44.1k 0.6s（`-af aformat=sample_fmts=flt`，EXTRABITS
    尾数补全路径） | f32le | ✓ |

  单测 `zig build test --summary all`：216/216 全绿（WavPack 新增：LSB-first 位流、wpExp2/
  wpLog2 定点表、median 收敛、getTail zigzag 区间、容器/熵/去相关/float 重建模块测试）。

  上线：`probe.formats.wv = true`（WavPack 接管）；DSD 调制在 `fmt/wv` open 判
  `error.UnsupportedFormat` 回退 FFmpeg 主后端（§9.9）。

- **APE 对照验收（2026-08-17，已完成）**：`kernel/ape_dump.zig` 直连 `fmt/ape/lib.zig`
  导出 PCM（16bit 样本 → s16；24bit 样本 → s32 顶对齐），与
  `ffmpeg -i <x.ape> -f s16le/s32le` 参考输出逐字节比对，全样本 bit-exact：

  | 样本 | 规格 | 参考格式 | 结果 |
  |---|---|---|---|
  | mac380-c2000 | v3.80 老格式 + bittable，normal 压缩，16bit 立体声 44.1k（entropy 0000 + predictor 3800） | s16le | ✓ |
  | mac388-c2000 | v3.88，normal（entropy 3860 + predictor 3800） | s16le | ✓ |
  | mac389b1-c4000 | v3.89，extra-high（entropy 3900 stereo 回退 + predictor 3800 + 长滤波 order 256） | s16le | ✓ |
  | mac391b1-c4000 | v3.91，extra-high（entropy 3930 + predictor 3930 + 终级滤波 {16,256,1280}） | s16le | ✓ |
  | mac392b2-c4000 | v3.92，extra-high（同上） | s16le | ✓ |
  | mac394b1-c2000 | v3.94，normal（entropy 3930 + predictor 3950 64-bit + 终级滤波 {64}） | s16le | ✓ |
  | mac394b1-c4000 | v3.94，extra-high（predictor 3950 + 终级滤波 {16,256,1280}） | s16le | ✓ |
  | partial | v3.99，high（entropy 3990 pivot + predictor 3950 + 终级滤波 {32,256}） | s16le | ✓ |
  | NoLegacy-cut | v3.99 24bit 立体声，high（interim_mode 双趟 + s32 顶对齐；截断帧部分解码 13824 样本） | s32le | ✓ |

  > 样本来源：FFmpeg FATE（`samples.ffmpeg.org/fate-suite/lossless-audio/`），
  > 已入库 `app/core/audio-engine/samples/ape/`；luckynight 系列为截断样本，
  > 对照限定前 73728 样本（`-af atrim=end_sample=73728`，对齐 FATE 参考）。
  > cover 样本（`luckynight_cover.ape`）为封面提取专用，音频轨损坏，不纳入对照。

  单测 `zig build test --summary all`：264/264 全绿（APE 新增：CRC-32 反射表向量、
  zigzag 符号解码、APESIGN 逆符号、getK、update_rice 收敛、bitreader MSB/unaryStop、
  容器 3800 老格式 / 3990 描述符 / peak level 偏移解析）。

  上线：`probe.formats.ape = true`（APE 接管）；纯自研无兜底（无外部依赖，AGPL）。
  版本 3800 以前 / FAST(1000) / INSANE(5000) 压缩级别样本缺失 → 后补验收（§9.10 风险控制）。
- **MP3 对照验收（2026-08-22，已完成）**：解码 PCM（float 中间态 → int16）与 **minimp3（CC0）**
  参考输出逐位比对（minimp3 标量路径 `MINIMP3_FLOAT_OUTPUT` + `MINIMP3_NO_SIMD` 编为参考解码器，
  导出 float PCM 后转 int16 对照，worst = 0），覆盖 Layer I/II/III 全链：

  | 样本 | 规格 | 结果 |
  |---|---|---|
  | minimp3_test 官方向量 | l1-fl1..8（Layer I）、ILL2_*（Layer II 20 项：center2/dual/mono/samples/scf63/tca21/tca30/tca30_PC/tca31_mtx0/tca31_mtx2/tca31_PC/tca32_PC/dynx22/dynx31/dynx32/ext_switching/layer1/layer3/multilingual/overalloc1/overalloc2/prediction）、performance（MEANDR_PHASE0/90、MIPSTest、noise_meandr）、fuzz（l3-compl-cut） | ✓ 37/37 |
  | 真实样本 | Layer III mono/stereo/MPEG1/MPEG2/MPEG2.5、8k-320kbps、CBR/VBR（ffmpeg 编码） | ✓ 18/18 |

  标签/时长对照：ID3v2（v2.2/2.3/2.4：标准字段 + 通用 tags + TXXX + APIC 封面 + UTF-8/16/Latin-1）、
  ID3v1 文件尾、ReplayGain（REPLAYGAIN_TRACK/ALBUM_GAIN/PEAK，单位对齐 AVReplayGain）、
  Xing/Info 头（VBR 时长 `duration_known = exact`）——与 ffmpeg 写入标签逐项一致，PCM 不受
  标签影响（带标签样本解码仍 bit-exact）。

  上线：`probe.formats.mp3 = true`（MP3 接管，已随 decoder 工厂接入）；纯自研无兜底
  （minimp3 仅作对照参考，非编译依赖，CC0）。
- **AAC-LC 对照验收（2026-08-23，已完成）**：解码 PCM（float 中间态 → s16）与参考构建
  输出逐位比对（worst = 0，见下），覆盖 mono/stereo × 正弦/粉噪、44.1k/48k：

  | 样本 | 规格 | 参考 | 结果 |
  |---|---|---|---|
  | t48_m | 48kHz 单声道正弦（ffmpeg aac 编码 96k） | 本地参考 `-f s16le` | ✓ 39936/39936 逐位一致 |
  | t44_st | 44.1kHz 立体声正弦（128k） | 本地参考 | ✓ 92160/92160 |
  | n44_st | 44.1kHz 立体声粉噪（160k） | 本地参考 | ✓ 81920/81920 |

  > 参考构建 = 本地从 `reference/FFmpeg` n9.0.1 源码 configure（`--disable-x86asm
  > --disable-optimizations`）编译，与参考源码逐位同源。系统 ffmpeg（LTO+AVX2）对照
  > 99.99%+ 一致，残留全部 ±1 LSB（构建浮点差异，非算法错误）。
  > s16 转换对齐 FFmpeg swresample：`av_clip_int16(lrintf(x*32768))`（最近偶数舍入）。

  验收覆盖（2026-08-23）：
  - **EIGHT_SHORT 短窗**（群分组 `[1,3,3,1]` 多组）、LONG_START/LONG_STOP 转换窗、
    稳态 ONLY_LONG；TNS（短窗 8 窗口迭代）、PNS（random_state 有符号位对齐）、
    MS/intensity 立体声、ESC 码本转义、VMUL4S 左对齐符号位；
  - 修复记录：跨组窗口基址累加（C `coef += g_len<<7`）、TNS 按 window 迭代
    （非 window_group）、PNS random_state 有符号 float 转换、case-1 符号左对齐、
    vector_fmul_window 索引（`dst[j]` 写第二半区）、s16 舍入 lrintf；
  - 上线：`probe.formats.aac = true`、decoder 工厂接入（AAC-LC 接管）；
    **M4A 内 AAC 轨**（mp4a+esds → ASC → 逐 sample 喂包）已接线，同一 `t48_m`
    源 M4A 输出与本地参考 100% 逐位一致（§17.2）；HE-AAC/SBR、chan_config>2 回退 FFmpeg。

- **Dolby 家族验收（2026-08-31，§9.14）**：
  - E-AC-3 参考为 **float(f32) 解码器**（s16 = round(f32×32768)）；样本：`test.eac3`
    （44100 sine）corr **1.0**（45% ±1）、`eac3_48k`（48000）corr **1.0**（44.4% ±1）、
    `csi_miami_stereo_128_spx_small`（fate SPX）corr 0.9998（4.7% ±1-4）；
  - **mono E-AC-3**（44100 噪声）：修复 cpl_strategy 分支后 corr **1.0**（前 4 样本
    `(0,0,-1,1)` vs ff `(0,1,-1,1)`，位级差 1 值）；
  - **TrueHD**：fate `atmos.thd` **bit-exact 40960/40960**（含 Atmos 标志检测）；
  - **Seek 验证**：Opus 5 位置（噪声）vs `ffmpeg -ss` corr **1.0 @ 偏移0**；AC-3 内部
    一致性 100%、stereo E-AC-3 3 位置 corr 1.0、mono E-AC-3 3 位置 corr 1.0；
    TrueHD seek50ms == 从头到 50ms（5120/5120）；AMR 51.5s 5 位置 position 精确 +
    corr 0.9991；
  - **标签验证**：M4A ilst（6 标准字段 + 8 tags）、Vorbis comment（6 字段 + 7 tags）
    均正确提取。
- **AMR-WB 误判（2026-08-31，§9.13）**：`#!AMR-WB\n` 现 probe 不再认领（`#!AMR\n`
  全等匹配）→ UnsupportedFormat 交 FFmpeg。

### 17.3 性能基线

- SRC：自研 FIR vs `swr_convert`，要求 ≤ 2× 时间且质量达标；
- 解码吞吐：每格式单核实时因子 ≥ 5×（对齐现状指标）；
- 首帧耗时：探测 + open 对标现状 `probesize=1MB / analyzeduration=0.5s` 的启动体验。

### 17.4 集成冒烟与安全

- 桌面：本地 flac/mp3/wav/ogg + **T1 全格式（alac/wv/ape/dsd/aiff/vorbis）**播放 + seek + FFT 拉模式
  + EQ/tempo 实时调整（AUTOPLAY 回归）；
- 在线：网易云（mp3/flac）、酷狗（mp3/flac）、QQ 音乐（P1：mp3 或 m4a）；
- 中断：SIGTERM / stop 正确退出，ASan/LeakSanitizer（`-fsanitize` 或 Zig Debug 模式）回归；
- 畸形输入：截断文件 / 随机字节 / 超大长度字段 → 无崩溃（fuzz 用 `std.testing` 随机种子）。

---

## 18. 构建与打包变更

| 项 | 变更 |
|---|---|
| `app/core/audio-engine/` | **C 壳保留**（`src/mediaengine_lib.c`/`main.c`/`pipeline.c`/`player.c` 等）；新增 `kernel/`（Zig 内核）与 `include/kernel_bridge.h`；FFmpeg 依赖代码拆至 `src/decoder_ffmpeg.c`/`resampler_ffmpeg.c`（默认编译，§8.3） |
| `CMakeLists.txt` / `rebuild-engine.sh` / `build/ffmpeg/` | 删除（FFmpeg 探测与运行库内嵌逻辑迁入 build.zig 的 `-Duse-ffmpeg` 分支 + 打包脚本，默认开） |
| `app/core/build-linux.sh` / `build-macos.sh` / `build_windows.bat` | 收敛为 `zig build -Dtarget=<三平台>` 包装（默认含 FFmpeg）；纯 Zig 构建加 `-Duse-ffmpeg=false` |
| `app/vcpkg.json` | `ffmpeg` 保留为**默认必需**（注释标注：Zig 全部接管后可改 feature）；`opus` 走 vendored（源码入库）；`nlohmann-json`（scraper）、`taglib/curl/openssl/sqlite3`（其他模块）、`pkgconf`(host) 均保留不动 |
| `.github/workflows/build-*.yml` | 默认 job 统一 `zig build -Dtarget=...`（含 FFmpeg，现状回归）；新增 job 覆盖 `-Duse-ffmpeg=false` 纯 Zig 渐进接管回归 |
| `app/linux|windows|macos/CMakeLists.txt` | 产物改名保持（`libarchoera_mediaengine.so/.dll/.dylib`、`libfft.so`、`archoera-audio-engine`），`native/` 平铺布局不变 |
| bundle 体积 | **默认构建保留 FFmpeg 运行库**（Linux 内嵌，体积同现状）；`-Duse-ffmpeg=false` 纯 Zig 构建才显著下降（新增 vendored libopus ~1MB） |
| 打包（`packaging/linux/` 等） | `native/` 布局与文件名不变，逻辑零改动；LGPL 合规说明（替换/重链权利）默认随发布版附带（同现状） |

---

## 19. 分阶段实施路线

| 阶段 | 内容 | 出口标准 |
|---|---|---|
| **Phase A** Zig 工程骨架 + 内核核心 + C 壳桥接 | `build.zig`（Zig 0.16，C 壳 + Zig 内核混合）落地；`kernel/io.zig` `probe.zig` `decoder.zig` `pcm/*`；`fmt/wav.zig`（自研）；DSP 移植为 Zig（`zk_dsp_*`）；`include/kernel_bridge.h` + `kernel/kernel.zig` 桥接，`pipeline.c` 解码经统一后端接口（FFmpeg 默认主 + Zig 接管分支） | 本地 wav 播放 + FFT + DSP 回归；`engine_bindings.dart` 零改动跑通；三平台 target 构建通过（默认含 FFmpeg） |
| **Phase B** FLAC / MP3 / OGG-Opus | `fmt/flac.zig`（自研，dr_flac 兜底）、`fmt/mp3/`（**自研完成**，§9.4）、`fmt/ogg.zig` + `fmt/opus.zig`（vendored libopus）；`encode/*`（libopus + 自研 OGG mux）；逐格式对照验收后开 `-Dzig-<fmt>=true` 接管 | 本地 flac/mp3/ogg/wav 播放 + seek + FFT；在线 mp3/flac 播放；CLI 批量 OGG/Opus 输出；接管格式与 FFmpeg 对照全绿（§17.2）。**MP3 已达标**（Layer I/II/III + 标签 + Xing，PCM 逐位一致） |
| **Phase C** AAC / M4A | `fmt/m4a.zig` `fmt/adts.zig`（自研容器）+ **`fmt/aac/` 自研 AAC-LC**（§9.5）；HE-AAC 回退 FFmpeg | 本地/在线 m4a/aac（LC）播放；未接管源（HE-AAC/长尾）由 FFmpeg 主引擎提供或明确错误 |
| **Phase D** T1 无损收藏 | **WavPack**（`fmt/wv.zig` 自研，libwavpack 兜底）、**ALAC**（自研，alac.c 兜底）、**APE**（`fmt/ape.zig` 自研解码器，§9.10）、**DSD**（`fmt/dsd.zig` 自研 DSF/DFF→PCM）、**AIFF**（并入 wav.zig）、**Vorbis**（vendored stb_vorbis） | 本地 wv/alac/dsd/ape/aiff/vorbis 播放 + seek + FFT；APE/ALAC/WavPack 与 FFmpeg bit-exact 校验全绿后接管 |
| **Phase E** 输出层 + 变速自研 | **`kernel/device.zig`**：先 Linux（ALSA/Pulse 动态加载）→ Windows WASAPI → macOS CoreAudio（§15）；经桥接替换 `src/player.c` 内的 miniaudio 调用；**WSOLA 变速**（`kernel/tempo.zig` 自研，tempo-rs 对照） | 三平台真机出声 + 位置事件正确；tempo A/B 主观 + 客观对照通过；`include/miniaudio.h` 与 Rust 依赖删除（输出层 100% Zig/自研） |
| **Phase F** 接管收尾（可选升主） | T0/T1 全部 Zig 验收后：各格式开关开启即完成接管，`-Dzig-main=true` 可选使 Zig 升为主（**默认仍 FFmpeg 主**）；`THIRD-PARTY-LICENSES.md` 按开关登记；设置页显示已编译解码器清单与 `backend` 归属；可选 AMR/WMA/MP2 按 §3.3 规则评估 | **默认构建**三平台 `ldd`/`dumpbin` 含 FFmpeg（现状回归通过）；`-Duse-ffmpeg=false` 纯 Zig 构建可裁剪、各格式开关独立可控；`zig build test` 全绿 |
| **Phase G** 引擎模块化 + 高并发（可与 A–F 并行推进） | §8.4/§8.4.2：`decoder.open()` 硬编码 `switch` 收敛为显式 `Module` 描述符 + Registry（主控：分派 + 实例簿记 + 资源上限）；**优先子项按 §8.4.2 顺序**：① 元数据快路径 `metadata.open()`（批量 tag 先摆脱 FFmpeg）→ ② 接管门控 → ③ 并发/批量基准 → ④ 实例内存池；HTTP 直连经 `io.Reader.callback` 接入（§6.1 双路径）；批量 tag/扫描走宿主 worker 池；每路轻量实例；FFmpeg 依赖拆分延后 Phase F。**二次增强（§8.4.1，后置可选，核心不依赖）**：主控 Async × 模块线 Sync + 完成即领（短任务）/ 按流分配分时驱动（长流） | Registry 分派与现状 `switch` 行为一致（全量回归）；实例计数/上限生效；128 路并发（同/异格式混合）fd 与内存受控、无状态污染；批量 tag 走 Zig 元数据快路径且不再建 FFmpeg 实例（基准吞吐达标）；HTTP 直连流式播放 + Range seek 正确；批量 tag 全量代替 FFmpeg 元数据路径；二次增强落地后加验"完成即领"下无线程空转/队列积压 |

---

## 20. 风险与决策点

| 风险/决策 | 说明 | 对策 |
|---|---|---|
| **FLAC 自研复杂度** | 无损解码（LPC/Rice/校验）~2500 行 | 目标自研；dr_flac（MIT-0/PD，单文件）兜底，`fmt/flac.zig` 接口隔离无缝切换 |
| **ALAC 自研复杂度** | 自适应预测 + Rice 熵编码 ~1800 行 | §9.8：Apple `alac.c`（Apache-2.0）对照 bit-exact 校验；兜底 alac.c |
| **WavPack 自研复杂度** | 块内预测/去相关 + Rice ~2500 行 | §9.9：libwavpack（BSD）对照 bit-exact 校验；兜底 libwavpack |
| **MP3 seek/时长精度** | 无帧级 seek 表；VBR 无 XING 头 | **已实现**（§9.4/§12.3）：Xing/Info 头 → 时长 exact + 精确 seek；无头 → 按首帧估算 + 帧同步扫描；`duration_known` 分级 |
| **AAC 集成** | AAC-LC 自研复杂度（ICS/TNS/PNS/MDCT 全链） | §9.5：**已完成**——参考 FFmpeg `aacdec.c` + 本地无优化参考构建逐位基准，本地参考 100% 一致、系统 ffmpeg 99.99%+（±1 LSB）；HE-AAC（SBR/PS）回退 FFmpeg 主后端 |
| **APE 自研复杂度** | range coder + 多预测器（~1500 行），预测器更新规则须逐位复刻 | §9.10：**已完成**——bit-exact 黄金文件（FATE 样本 3.80-3.99，§17.2）+ FFmpeg `apedec.c` 对照 + 帧 CRC 三重校验全绿后接管（`probe.formats.ape=true`）；版本 <3.80 / FAST / INSANE 样本缺失待补验；极端失败才考虑 §3.3 vendored 回退（许可另行审查） |
| **WMA 生态** | 无干净 permissive 单文件解码器（FFmpeg 之外的生态稀缺） | 列 T2 低优先；Phase F 按需评估；不做承诺 |
| **DSD 转 PCM 质量** | 抽取/低通滤波质量决定听感 | 自研 CIC/多级 IIR + 可对照参考（如 `dsd2pcm`）；耳听 + 频谱双重验证 |
| **SRC 质量/性能** | 自研 FIR 需对标 swr | 多相 FIR + 独立基准；不达标 vendored libsamplerate（BSD） |
| **输出层自研复杂度** | 三平台设备 API（ALSA/Pulse/PipeWire/WASAPI/CoreAudio） | §15 增量落地：先 Linux 后 Windows/macOS；真机验收；miniaudio 兜底不阻塞 |
| **macOS 交叉编译** | 输出层（CoreAudio）需 SDK | 内核可交叉；全量在 macOS CI job 构建；Linux 宿主只做内核/其他平台交叉编译 |
| **miniaudio 体积/维护** | 单文件 4MB 头 | 仅过渡兜底；device.zig 完成即移除（§15.2） |
| **OGG 尾页扫描开销** | Opus 精确时长需读尾页 | 先 estimate 后回填；position 事件不受影响 |
| **格式开关膨胀** | 每个开关带来源码 + 测试 + 许可登记 | 默认只开 T0；扩展格式独立开/关、独立审查；未开格式 probe 判 unsupported 不误报 |
| **在线源格式漂移** | 平台新增编码 | 探测失败明确错误 + 音源降级（换 flac/mp3）；记录 `unsupported` 日志 |
| **WSOLA 变速质量** | 变速变调自研质量需对标 signalsmith | §9.6：主观 A/B + 客观互相关/频谱包络对照；不达标保留 tempo-rs |
| **FFmpeg 双轨维护成本** | FFmpeg 默认主 + Zig 逐格式接管意味着两条解码路径并存 | FFmpeg 是现状稳定基线（不新增维护负担）；Zig 接管以 §17.2 对照为门槛、按格式收敛；事件带 `backend` 字段监控接管率/回退率；接管完成的格式可 `-Dzig-<fmt>=false` 回退；`-Duse-ffmpeg=false` 纯 Zig 构建随时可验证 |
| **Web 兼容路径存废** | 桌面不编码 | Phase A 临时禁用；确认废弃则删 `encode/` |
| **高并发资源失控** | 128+ 路同时 open，fd/内存/CPU 被打满 | §8.4 主控簿记 + `cap` 上限（fd/内存双护栏）报 `error.InstanceLimit`；宿主 worker 池并发限流；HTTP 直连每实例极轻（几十 KiB 级） |
| **多路状态污染** | 共享模块被某实例改写 → 杂音/崩溃 | 模块只含函数指针 + `comptime const` 表（零可变成员）；一切运行时状态存实例 ctx；主控强制模块只读约定（§8.4 不变量 1） |
| **HTTP 直连依赖边界漂移** | 网络能力被误塞回内核，破坏 P2 零网络栈 | 传输（socket/TLS/Range/重定向）一律宿主注入，内核仅 `callback` 消费字节流；不支持网络栈退回预下载（§6.1） |

---

## 21. 决策记录

1. **语言：Zig**（`build.zig` 单一构建系统 + 交叉编译 + freestanding + `@cImport`），替代 C + CMake + 三平台脚本。
2. **跨平台优先（P1）**：内核核心零平台差异、可任意宿主交叉编译；平台差异仅存在于输出层（macOS 需 SDK，
   由 macOS CI job 全量构建；Linux/Windows 交叉/本地构建）。
3. **自研优先（P2，2026-08-15 强化；2026-08-22 MP3 修正）**：容器/采样/DSP/封装/输出层全部自研 Zig；无损编解码
   （FLAC/APE/ALAC/WavPack）自研并 bit-exact 校验；MP3 亦自研（minimp3 CC0 参考逐位验收，见 §3.7 裁决变更）；
   仅 Opus/AAC 因数学复杂度不可自研而 vendored（Permissive 单文件或源码入库，零构建期下载）。裁决见 §3.7。
4. **依赖账本（最终形态）**：自研=WAV/AIFF/OGG/MP4/ADTS/DSF/DFF/WV 容器 + 采样三件套/DSP/OGG 封装/
   DSD→PCM + **FLAC/APE/ALAC/WavPack/MP3 解码器** + **device.zig 输出层** + **WSOLA 变速**；
   vendored 单文件=stb_vorbis（Vorbis）+ miniaudio（输出过渡兜底）+ dr_flac/alac.c/
   libwavpack（各自研兜底）；
   vendored 源码=libopus（Opus，唯一正式库）+ OpenCORE（AAC，P1）；
   tempo-rs（Rust）仅作 WSOLA 过渡兜底。
   **不引入（默认）**：faad2 / libfdk-aac / WMA（生态待评估）；FFmpeg 保持默认主引擎（见 #5/#13）。
5. **FFmpeg 默认主引擎、Zig 渐进替换（P3，2026-08-16 修订）**：**默认构建启用 FFmpeg**（链接
   `libav*` / `libsw*`，行为同现状零回归）；Zig 内核逐格式验收后按格式接管（格式级开关
   `-Dzig-<fmt>=true`），全部 T0/T1 接管后可选 `-Dzig-main=true` 使 Zig 升为主（默认仍 FFmpeg）；
   `-Duse-ffmpeg=false` 得纯 Zig 构建（仅接管格式可播）；视频解码不做、不支持（P4）。
6. **行为兼容（P5）**：`archoera_mediaengine.h` 导出符号与 JSON 协议、`libfft.so` Dart ABI、
   `stream.wav`/`stream.pcm` 落盘格式不变；Dart 侧仅新增"在线源预下载临时文件"。
7. **解码器统一接口 `kernel/decoder.zig`**：输出原生位深交错 PCM，采样转换由
   `convert + downmix + resampler（多相 FIR）` 三件套处理。
8. **格式插件化（P6）**：comptime 特性开关逐格式编译/裁剪，默认只含 T0；未开格式 probe 判 unsupported
   （FFmpeg 默认主，未接管/未开格式由 FFmpeg 提供，§3.6）；每格式独立许可审查并登记 `THIRD-PARTY-LICENSES.md`。
9. **时长/seek 分级**：exact/estimate/unknown；MP3 首遍索引 + XING；Opus 尾页回填。
10. **中断**：`Reader.abort()` 原子标志替代 AVIOInterruptCB；Zig error set 统一错误模型。
11. **许可合规**：新引入仅限 MIT-0/PD/BSD-3/Apache-2.0，逐一登记 `THIRD-PARTY-LICENSES.md`；
    **APE 解码器为自研 Zig 实现**（参考对照 FFmpeg `apedec.c`，许可登记见 `audio-engine/THIRD-PARTY-LICENSES.md`），不依赖 Monkey's Audio 官方 SDK。
12. **自研扩张原则（2026-08-15，2026-08-16 修订为渐进接管）**：凡"无损可 bit-exact 校验 + 有参考实现"
    的编解码器一律自研（FLAC/APE/ALAC/WavPack）；输出层与变速变调亦自研（device.zig / WSOLA）；
    miniaudio、tempo-rs、dr_flac、alac.c、libwavpack 仅作过渡/兜底，自研验收后移除。
    **FFmpeg 保持默认主引擎**（`-Duse-ffmpeg` 默认开），Zig 内核按格式验收后逐格式接管
    （`-Dzig-<fmt>=true`）；`-Duse-ffmpeg=false` 纯 Zig 构建最终内核 100% Zig/自研（仅 libopus 一个外部库）。
13. **架构调整（2026-08-16，用户决策）：FFmpeg 默认主 + C 壳保留 + Zig 渐进替换**——FFmpeg 保持
    默认主解码引擎（`-Duse-ffmpeg` 默认开启，行为同现状零回归，发布版默认带 LGPL 动态链接 +
    合规说明）；C 调用壳（`mediaengine_lib.c` / `main.c` / `pipeline.c` / `player.c`）保留，
    经 `kernel_bridge.h`（`zk_*`）调用 Zig 内核，Dart FFI 符号面零改动；Zig 内核逐格式验收后
    **按格式接管**，未接管格式始终由 FFmpeg 提供；全部 T0/T1 验收后可选 `-Dzig-main=true` 升主，
    默认仍 FFmpeg。参考实现：`reference/FFmpeg`（2026-08-16 克隆，n9.0.1，§2.1）。
14. **AAC 解码器自研（2026-08-23，用户决策"尽可能自主实现"）**：AAC 由 🔴 vendored OpenCORE
    改为 ✅ 自研 Zig（`fmt/aac/`，AAC-LC，§9.5），与 MP3/Opus 同模式——参考 FFmpeg
    `aacdec*.c` 浮点路径 + 本地无优化参考构建作逐位基准（§17.2）。范围：AOT 2 (LC) 无
    SBR/PS，SCE/CPE/DSE/FIL + MS/intensity/TNS/PNS/pulse 全支持，HE-AAC 回退 FFmpeg；
    验收：本地参考 s16 输出 **100% 逐位一致**（3 样本，ADTS 裸流 + M4A 容器双路径，
    §17.2），系统 ffmpeg 99.99%+（残留 ±1 LSB 构建差异）。接线：`probe.formats.aac`、
    decoder 工厂、**M4A 内 AAC 轨**（mp4a+esds → ASC → 逐 sample 喂包）全部接入。
    ADTS/M4A seek 为整帧对齐（帧级精度，同现状 FFmpeg AVSEEK_FLAG_BACKWARD）。
15. **内存播放（不落盘）模式（2026-09-08 决策）**：桌面播放**默认内存模式**（独立开关，
    与 Stable/EraAudio、SongCache 均独立）。解码 PCM 驻留进程内**全量块列表**（与 stream.pcm
    文件块同构；达 cap 才滚动淘汰），频谱经新 FFI `archoera_mediaengine_pcm_window` / `_epoch`
    拉窗，**不写 `stream.wav/.pcm`**；无设备 + 内存模式 → error（不文件回退）；`cap`：
    auto（按可用内存均衡，**0.8 GiB 硬上限**：查询故障回落、append 后记账强制淘汰、绝不越过
    用户设限）/ 自定义上限 / 无上限（须显式警告内存过载后果）。
    文件模式（设置关 / `ARCHOERA_ENGINE_FILE_MODE=1`）保留现状字节级行为（PARITY 基准在
    文件模式下执行；内存模式按窗口比对）。规格与验收：`docs/audio-memory-playback.md`。
16. **进程内模块化引擎（2026-09-08，用户决策；HTTP 直连并行开展）**：引擎向"1 主控 Registry →
    N 格式模块 → M 轻量实例"演进（§8.4，Phase G）：模块 = `fmt/*`（纯函数 + `comptime const` 表，
    全局只读一份）；实例 = 现有 `decoder.Decoder`（每模块任意多）；主控只做探测分派 + 实例簿记 +
    资源上限（原子计数，超 `cap` 报错），**仍不持线程**——执行调度在宿主 worker 池。目标支撑
    **128 路并发**（HTTP 直连 / 批量 tag / 扫描等），规避 FFmpeg"N 路 = N×(完整引擎上下文)"开销爆炸；
    仅覆盖 Zig 接管格式，FFmpeg per-context 兜底不变（§8.3）。零拷贝仅限单线程 Sync-Direct；
    HTTP 直连经 `io.Reader.callback`（on_read/on_seek + Range），传输由宿主注入，内核保持零网络栈（P2）。
     依据：FFmpeg 模型对高并发资源放大 + 用户对 FFmpeg 多线程/实例化开销不满（详见 §8.4 动机）。
     修订 2026-09-09：本项"主控不持线程、执行调度在宿主 worker 池"已被
     `docs/engine-master-pool-design.md` 取代——执行调度线程（Master 事件线程 + Pool worker）
     内迁至 Zig 内核，主控仍只做簿记 / 分派 / §5.5 容量调节（详见该文档）。
17. **执行与调度模型（2026-09-08，决策 #17）：主控 Async × 模块线 Sync + 完成即领（内核二次增强）**：
     定位为**后置可选**，Phase G 核心（Registry + §8.4.2 优先子项 #1–#4）不依赖，可先以纯 Sync 最小
     形态运行再引入。主控（Registry/
    调度器）以 **Async**（事件驱动、非阻塞，可跑宿主事件循环，仍不持内核线程）管理派发与簿记；模块
    工作线为宿主 OS 线程上的 **Sync** 解码循环（单流帧级串行，天然正确）。短任务（批量 tag/扫描/
    批量转码）用 **pull / eager-next**：M 条常驻线"干完一件立即向主控领下一件"，主控只维护 next 游标/
    空闲线集合 → 无线程空转、无中心队列积压、无 IO 过载；长生命周期流（128 播放/HTTP 直连）按流分配
    + 每线 K 路帧级分时驱动，避免 1 流 = 1 线重模型。tag 批量确认适用完成即领。单流内不做帧级
    async/多线程（状态依赖 + 协程不适配 CPU 密集解码）。爆炸源（复用 FFmpeg 通用解码循环的 per-instance
     完整上下文）随逐格式接管消解，调度模型不放大开销（§8.4.1）。
     修订 2026-09-09：本项执行形态已由 `docs/engine-master-pool-design.md` 落地为 Zig 内核内的
     Master async 事件线程 + M 条 Sync worker（worker 不自建、不自杀；线程创建/退出归 Master
     async 独占；任务切换仅限完全空闲边界）。"长流每线 K 路帧级分时"取消，改 **pinned 1:1
     流式会话**（该文档 §6.3）。
18. **Phase G 优先子项（2026-09-08，决策 #18）**：在调度模型之外、按收益/成本排序的性价比清单（§8.4.2）：
    ① **元数据专用快路径 `metadata.open()`**——批量 tag/扫描只需 demux/tag（Zig 全格式具备），
    EraAudio"残血"不阻碍；每文件从"FFmpeg 完整实例"降为"几十 KiB 的 Zig Reader"；
    ② **接管门控**——静态接管位图，未接管格式直进 FFmpeg、接管格式不建 FFmpeg 上下文，消除
    EraAudio 分支下"先试 Zig 再回退"的双倍 open 成本；③ **N 实例并发 + 千文件批量 tag 基准**先行量化，
    防过度工程；④ 实例内存池/Reader 缓冲复用（保持 pread、无预读优点）。FFmpeg 依赖文件拆分
    （decoder.c→decoder_ffmpeg.c）属文件组织，**延后至 Phase F**。落地顺序 ①→②→③→④。
19. **消费方与线程参数策略（2026-09-08，决策 #19；详见 engine-master-worker-scheduling.md §2.2/§2.3）**：
    线程数 **M 运行时可配**，按消费方场景取：独立启动（CLI/批量）由用户 `--thread <n>` 指定（对齐
    main.c CLI 风格）；播放器内嵌**默认 1**（顺序单流）；scanner 批量接线取较大值（经优先子项③基准定）。
    实例 cap 短任务批量 ≥ M、长流独立上限（fd/内存护栏）。**scanner 接线为 Phase G 试点**：批量 tag 任务
    （现 TagLibSharp 并行解析）改投本引擎 `kind=tag`，走元数据快路径，接线形式（native FFI / CLI-子进程）
    待定。主控事件循环载体与 per-handle 线程模型迁移路径仍待定。
20. **scanner 接线与模块总线方向（2026-09-08，决策 #20；详见 engine-master-worker-scheduling.md §2.3/§2.4）**：
    scanner（NativeAOT C#，与引擎同进程）**模块间 C ABI 直连**引擎，不经 Dart 逐文件中转；A/B 形态 =
    新增轻量 `zk_metadata_*`（probe+tag 即走，不构造 decoder），结果走**结构化 extern struct**（`ZkMetaInfo`）
    且**规避 JSON**（JSON 仅留低频控制面）；**EraAudio 优先、TagLib 兜底（不抛弃）**，保留对照开关。
    为支撑未来**系统占用/播放器日志面板**，规划进程内统一**模块通讯/遥测总线**（`bus_publish/subscribe` +
    环形缓冲，结构化事件），低频遥测与日志走总线，per-file 高吞吐仍走直连 ABI（§2.4 边界）。
