# 独立音频内核设计（Zig · 零 FFmpeg · 最小依赖 · 跨平台优先）

> 状态：**设计稿 v1 · 2026-08-15**
> 定位：用 **Zig** 重写 `app/core/audio-engine/`，得到一套**完全不依赖 FFmpeg**、**最小外部依赖**、
> **天然跨平台**的独立音频内核。只做**音频**，**不做任何视频解码**。
>
> 替代：`docs/audio-kernel-no-ffmpeg.md`（C11 方案，已废弃，保留作历史分析；其 FFmpeg 依赖点审计、
> 时长/seek、容错、测试护栏等结论仍适用，冲突处以本文为准）。
>
> 依据：AGPL-3.0 项目，任何引入的第三方必须为 Permissive（MIT / Apache-2.0 / BSD / ISC / OFL /
> MIT-0 / 公有领域）且与 AGPL 兼容（README「许可证」章节）。

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
| **P3** | **零 FFmpeg** | 不链接、不依赖任何 `libav*` / `libsw*` |
| **P4** | **纯音频、无视频** | 视频轨不处理、不支持、不探测；容器只解析音频轨 |
| **P5** | **行为兼容（迁移护栏）** | `archoera_mediaengine.h` FFI 导出符号、事件/命令 JSON 协议、`libfft.so` 的 Dart ABI、`stream.wav` / `stream.pcm` 落盘格式**全部不变**；Dart 侧仅新增"在线源预下载"一步 |
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
| **可直接编译 C 单文件** | `addCSourceFiles` + `@cImport`，vendored 的单文件 C 库（如 dr_mp3）零改造编译进内核，C 头 API 可直接 `@cImport` 调用 |
| **导出 C ABI** | `export fn xxx(...) callconv(.C)` 导出与现状 C 引擎**同名同签名**的符号，Dart FFI（`engine_bindings.dart`）零改动 |
| **安全默认 + 性能** | 处理不可信媒体输入时，Zig 的边界/溢出检查（Debug/Safe 模式）+ ReleaseFast 高性能，天然比 C 稳 |
| **std 自足** | 自带 allocator、fs、thread/mutex/cond、哈希（含 CRC）、ArrayList 等，内核基础设施不再依赖任何三方库 |
| **一个语言贯穿** | 解码 / 采样 / DSP / FFI / CLI / 测试全用 Zig 完成，无 C/Rust/脚本混合心智负担（tempo-rs 仅作过渡兜底，自研 WSOLA 完成后移除，见 §9.6） |

> **不选 C 的理由**：现状 C 方案仍依赖 CMake + 三平台脚本 + FFmpeg/vcpkg 打包链，且"复用 miniaudio 内嵌
> dr_*"意味着依赖 miniaudio 单头文件整体（含输出层），与 P2 冲突；Zig 能把"自研优先"贯彻到底，
> 并一次性解决跨平台构建。

---

## 3. 技术选型总览：依赖账本

### 3.1 一句话结论

> **内核 100% 自研 Zig：IO / 探测 / 解复用 / 采样 / DSP / 封装 / 播放输出层全部自研；
> 无损编解码（FLAC / APE / ALAC / WavPack）自研（可用参考实现 bit-exact 校验）；
> 仅"数学复杂度确实无法自研"的 MP3 / Opus / AAC 引入 Permissive 实现；
> 音频输出层自研 Zig，miniaudio 仅作过渡兜底。**
> 全项目最终仅 libopus 一个"正式第三方库"（Opus 编解码），其余均自研或 vendored 单文件（源码入库）。

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
| **ALAC 解码** | **自研 Zig**（目标，~1800 行）；alac.c（Apache-2.0）兜底 | AGPL | 无损可 bit-exact 校验；Apple 参考 alac.c 作对照 |
| **WavPack 解码** | **自研 Zig**（目标，~2500 行）；libwavpack（BSD）兜底 | AGPL | 无损/混合可 bit-exact 校验；libwavpack 作对照 |
| DSD→PCM | **自研 Zig**（~400 行） | AGPL | 1-bit 抽取 + 低通，纯信号处理 |
| **MP3 解码** | **vendored `dr_mp3`（单文件 C）** | MIT-0 / PD | MP3 Layer III 自研 ≈5000+ 行（IMDCT/霍夫曼/滤波器组），数学复杂度不可行；dr_mp3 单文件、许可最宽松 |
| **Opus 解码 + 编码** | **vendored `libopus` 源码** | BSD-3-Clause | Opus 参考实现 ~5 万行，自研不可行且必须支持；vendored 源码经 Zig 编译 |
| **AAC 解码** | **vendored `OpenCORE AAC`（Apache-2.0）**，或**平台降级** | Apache-2.0 | AAC 解码不可自研；OpenCORE 许可合规；受阻时平台侧优先请求 mp3/flac（§9.5） |
| 音频输出（播放设备） | **自研 Zig `device.zig`**（目标）；miniaudio 过渡兜底 | AGPL / MIT-0-PD | 三平台设备 API 自研可控（§15），消除最后一个 C 依赖 |
| 变速变调 | **自研 Zig WSOLA**（目标）；tempo-rs 过渡兜底 | AGPL / MIT | WSOLA 自研可行（§9.6）；tempo-rs 仅作迁移期参考 |

### 3.3 "自研 vs 引入"决策规则（P2 落地方案）

```
1. 数学/算法复杂度自研可行（容器解析、采样数学、DSP、设备输出）→ 一律自研 Zig
2. 编解码器：自研工作量可控且有可对照参考实现（无损编解码可 bit-exact 校验）→ 自研
   （FLAC、APE、ALAC、WavPack——均有无损 bit-exact 校验 + 参考实现可逐位对照）
3. 其余编解码（MP3/Opus/AAC）→ 数学复杂度不可自研，引入 Permissive 实现，且必须满足：
   a. 单文件 C（dr_mp3 / miniaudio）或可 vendored 源码（libopus / OpenCORE）
   b. 源码入库（git），构建期零下载
   c. 许可证 ∈ { MIT / MIT-0 / PD / BSD / Apache-2.0 } 且与 AGPL 兼容
4. 每个 vendored 组件必须登记"是否可自研"的裁决结论（§3.7），新格式一律先按自研评估
5. 明确不引入：FFmpeg（LGPL，正是要移除的）、faad2（GPL）、libfdk-aac（非自由）、
   任何 GPL/SSPL/商业源可用（README 红线）
```

### 3.4 与既有 `audio-kernel-no-ffmpeg.md` 的差异

| 项 | C 方案（旧） | Zig 方案（本稿） |
|---|---|---|
| 语言 / 构建 | C11 + CMake + 三平台脚本 | Zig + 单一 `build.zig`，交叉编译 |
| P0 解码器 | 复用 miniaudio 内嵌 dr_mp3/dr_flac/dr_wav | FLAC **自研**（dr_flac 兜底）；dr_mp3 仍 vendored；miniaudio 仅输出层过渡兜底 |
| libc | 必链 | 内核 freestanding（可选链接） |
| 平台差异 | 隐藏在各平台脚本 | 收敛到构建 target + 自研输出层边界 |
| 依赖面 | miniaudio（含输出层）为主要复用 | 自研优先；仅不可自研编解码器引入（§3.7 裁决） |

### 3.5 格式覆盖总表（本地播放器兼容面，P6）

> 覆盖基线对齐 C# 扫描器 `ScannerEngine.cs:33-34` 的扩展名清单
> （mp3/flac/ogg/opus/oga/m4a/aac/wav/ape/wv/dsf/dsd/dff/mp4/aiff/aif），
> 并扩充到常见的 Hi-Res / 无损收藏格式。**容器（解复用）与编解码分离**：容器尽量自研，
> 编解码按 §3.3 规则自研或 vendored。

| 优先级 | 格式 | 容器实现 | 解码实现 | 许可证 | 状态 |
|---|---|---|---|---|---|
| **T0 核心** | MP3 | `fmt/mp3.zig`（帧头/索引） | dr_mp3（单文件 C） | MIT-0/PD | Phase B |
| **T0 核心** | FLAC | `fmt/flac.zig`（帧/校验自研） | **自研 Zig**（~2500 行）；dr_flac 兜底 | AGPL / MIT-0/PD | Phase B |
| **T0 核心** | WAV / AIFF / W64 / RF64 | `fmt/wav.zig` 自研 | 自研（PCM/IEEE float） | AGPL | Phase A |
| **T0 核心** | OGG/Opus | `fmt/ogg.zig` 自研 | vendored libopus | AGPL / BSD-3 | Phase B |
| **T0 核心** | OGG/Vorbis | `fmt/ogg.zig` 自研 | vendored stb_vorbis（PD 单文件；自研评估结论见 §3.7） | AGPL / PD | Phase D |
| **T0 核心** | AAC / M4A / ADTS | `fmt/m4a.zig` `fmt/adts.zig` 自研 | vendored OpenCORE | AGPL / Apache-2.0 | Phase C |
| **T1 无损收藏** | ALAC（M4A 内） | `fmt/m4a.zig` 自研 | **自研 Zig**（目标，~1800 行）；`alac.c` 兜底 | AGPL / Apache-2.0 | Phase D |
| **T1 无损收藏** | WavPack（.wv） | `fmt/wv.zig`（自研容器 ~150 行） | **自研 Zig**（目标，~2500 行）；libwavpack 兜底 | AGPL / BSD-3 | Phase D |
| **T1 无损收藏** | APE（Monkey's Audio） | `fmt/ape.zig`（自研容器 ~200 行） | **自研 Zig 解码器**（range coder + 多预测器，~1500 行，参考 FFmpeg `apedec.c` 校验，§9.10） | AGPL | Phase D |
| **T1 无损收藏** | DSD（.dsf/.dff/.dsd） | `fmt/dsd.zig` 自研 | **自研**（DSD→PCM 抽取滤波） | AGPL | Phase D |
| **T1 常见** | AMR（.amr/.3gp 音频） | `fmt/amr.zig` 自研 | vendored OpenCORE AMR | Apache-2.0 | Phase F 可选 |
| **T2 长尾** | WMA（.wma） | — | **生态待评估**（无干净的 Permissive 单文件） | ⚠️ 低优先 | Phase F 可选 |
| **T2 长尾** | MP2 / Speex / AU / CAF / GSM | 容器自研 | 按 §3.3 规则逐项评估 | — | Phase F 可选 |

> **容器 vs 编解码分离的意义**：一个"有视频轨的 MP4"也要能取音频（`fmt/m4a.zig` 只解析 `mp4a`），
> 而"纯音频 M4A（ALAC/AAC）"复用同一容器模块——加格式往往只加一个解码器 + 一行注册，不动容器。

### 3.6 格式插件化（comptime 特性开关，P6 的落地）

Zig 在**编译期**按 `build.zig` 选项裁剪模块，默认构建只含 T0，需要时开启扩展：

```zig
const formats = .{
    .wav   = true,   // 自研，T0 默认开
    .flac  = true,   // 自研，T0 默认开
    .mp3   = true,   // dr_mp3，T0 默认开
    .ogg   = true,   // 自研解复用，T0 默认开
    .opus  = true,   // vendored libopus，T0 默认开
    .m4a   = false,  // 自研容器 + OpenCORE（Phase C 开）
    .alac  = false,  // 自研（目标，alac.c 兜底）（Phase D 开）
    .wv    = false,  // 自研（目标，libwavpack 兜底）（Phase D 开）
    .ape   = false,  // 自研解码器（Phase D 开；实现完成前默认关）
    .dsd   = false,  // 自研（Phase D 开）
    .vorbis = false, // vendored stb_vorbis（Phase D 开）
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

- **默认产物体积**：只含 T0，与现状相当（甚至更小——去掉了 FFmpeg）；
- **开启成本**：一条 `build.zig` 选项 + 对应 vendored 源码入库（自研模块无需任何外部源码）；
- **单一许可证审查**：每个格式模块独立审查，`THIRD-PARTY-LICENSES.md` 按开关登记；
- 后端 UI 可暴露"已编译解码器清单"（`format_name` 枚举随 `ready` 事件带出），方便用户排查。

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
| **APE 解码** | 🟡 自研目标 | 无损 bit-exact + FFmpeg `apedec.c` 参考 | 不依赖官方 SDK |
| **ALAC 解码** | 🟡 自研目标 | 无损 bit-exact + Apple `alac.c`（Apache-2.0）参考 | alac.c 兜底 |
| **WavPack 解码** | 🟡 自研目标 | 无损 bit-exact + libwavpack（BSD）参考 | libwavpack 兜底 |
| **变速变调（tempo）** | 🟡 自研目标 | WSOLA 可实现 + 主观/客观对照 | tempo-rs 兜底 |
| **播放输出层** | 🟡 自研目标 | 平台设备 API 直调（§15） | miniaudio 兜底 |
| **MP3 解码** | 🔴 vendored（不可自研） | Layer III ≈5000+ 行，数学复杂度高 | dr_mp3（MIT-0/PD） |
| **Opus 解码 + 编码** | 🔴 vendored（不可自研） | 参考实现 ~5 万行 | libopus（BSD，源码入库） |
| **AAC 解码** | 🔴 vendored（不可自研） | ~1 万行 + HE-AAC 组件 | OpenCORE（Apache-2.0） |
| **Vorbis 解码** | 🔴 vendored（ROI 低） | 有损、无 bit-exact 参考；需 MDCT+码本+floor+残差全链 | stb_vorbis（PD 单文件） |
| **AMR / WMA / 长尾** | 🔴 vendored 或砍（按需评估） | 低频格式 | 按 §3.3 评估 |

> **裁决判据**：是否无损（有无 bit-exact 校验闭环）+ 是否有可逐位对照的参考实现 + 自研量是否可控。
> 前三个"🔴"（MP3/Opus/AAC）是数学复杂度不可逾越的边界，vendored 是唯一解；
> Vorbis 是"可行但 ROI 低"（有损无 bit-exact、已是黄昏格式），vendored PD 单文件收益更高。

---

## 4. 架构与模块

### 4.1 目录结构（Zig 工程）

```
app/core/audio-engine/                # Zig 重写（原 C 源码迁移至 legacy/ 过渡，见 §18）
├── build.zig                         # 单一构建脚本（lib / CLI / tests / fft-shared）
├── build.zig.zon                     # 依赖声明（当前应为空——零包依赖）
├── src/
│   ├── mediaengine.zig               # FFI 库：export archoera_mediaengine_*（替代 mediaengine_lib.c）
│   ├── cli.zig                       # CLI：archoera-audio-engine（替代 main.c）
│   ├── kernel/
│   │   ├── io.zig                    # 输入抽象（Reader：file/mem/callback + peek/seek/abort）
│   │   ├── probe.zig                 # 格式探测（魔数嗅探）
│   │   ├── decoder.zig               # AudioDecoder 接口 + 解码器工厂
│   │   ├── engine.zig                # 管线编排（decode→pcm→dsp→encode，替代 pipeline.c）
│   │   ├── error.zig                 # 统一错误码/错误集合
│   │   ├── fmt/
│   │   │   ├── wav.zig               # 自研：WAV/AIFF/W64/RF64（T0）
│   │   │   ├── ogg.zig               # 自研：Ogg 页解复用 + granule/CRC（T0）
│   │   │   ├── m4a.zig               # 自研：MP4/M4A 音频轨（T0 AAC / T1 ALAC）
│   │   │   ├── adts.zig              # 自研：AAC 裸流（T0）
│   │   │   ├── flac.zig              # 自研（dr_flac 兜底）（T0）
│   │   │   ├── mp3.zig               # dr_mp3 封装（含首遍索引）（T0）
│   │   │   ├── opus.zig              # libopus 封装（解码）（T0）
│   │   │   ├── alac.zig              # 自研（alac.c 兜底）（T1，Phase D）
│   │   │   ├── wv.zig                # 自研（libwavpack 兜底）（T1，Phase D）
│   │   │   ├── ape.zig               # 自研解码器（T1，Phase D）
│   │   │   ├── dsd.zig               # 自研 DSF/DFF + DSD→PCM（T1，Phase D）
│   │   │   └── vorbis.zig            # vendored stb_vorbis（T0，Phase D）
│   │   │   └── amr.zig               # vendored OpenCORE AMR（T1，Phase F 可选）
│   │   ├── pcm/
│   │   │   ├── convert.zig           # 采样格式转换（int→float32 交错）
│   │   │   ├── downmix.zig           # 声道下混（ITU-R BS.775）
│   │   │   └── resampler.zig         # 采样率转换（多相 FIR）
│   │   ├── dsp/
│   │   │   ├── equalizer.zig         # 10 段 Biquad（移植）
│   │   │   ├── loudness.zig          # EBU R128 增益（移植）
│   │   │   ├── limiter.zig           # 限幅（移植）
│   │   │   └── fft.zig               # FFT 分析（移植；同时导出 libfft.so ABI）
│   │   └── tempo.zig                 # 自研 WSOLA（目标）；tempo-rs FFI 兜底（§9.6）
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
│   ├── miniaudio.c                   # MINIAUDIO_IMPLEMENTATION（唯一实例化点；device.zig 完成后删除）
│   ├── dr_mp3.c                      # MP3 解码（不可自研，常驻）
│   ├── dr_flac.c                     # FLAC 兜底（自研完成前）
│   ├── alac.c                        # ALAC 兜底（自研完成前，Apache-2.0）
│   ├── wavpack/                      # libwavpack 兜底（自研完成前，BSD-3）
│   └── opus/                         # vendored libopus 源码（仅 Opus 必需，常驻）
├── tempo-rs/                         # WSOLA 过渡兜底（Rust 变速变调静态库，自研完成后删除）
├── include/
│   └── archoera_mediaengine.h        # 保留：FFI 头（声明与 Dart 契约；Zig 可 @cImport 校验一致性）
└── tests/                            # Zig test 源（黄金文件 + 一致性对比）
```

### 4.2 数据流（与现状一致）

```
source（本地文件 / Dart 预下载临时文件）
  → kernel.io.Reader → kernel.probe → kernel.decoder.open
  → fmt/*.read() → 原生格式交错 PCM
  → pcm.convert → float32 交错
  → pcm.downmix → 目标声道
  → pcm.resampler（passthrough 直通）
  → dsp: EQ → loudness → limiter → tempo → FFT
  → 桌面：PCM 落盘 float32 WAV → device/player.zig（自研输出层；过渡期 miniaudio 兜底）自播（skip_encoder）
  → Web/批量：encode.opus_encoder + encode.ogg_muxer → OGG/Opus
```

### 4.3 不变量（迁移护栏，对齐 P5）

1. `archoera_mediaengine.h` 导出符号与语义不变（`create/command/poll_event/session_dir/is_done/destroy`）；
2. `audio_engine.h` 的 `EngineConfig` 字段与 `pipeline_*` 公开 API 语义不变；
3. 桌面输出：float32 WAV + `stream.pcm`（`[pos_ms|samples|channels]+float`）不变；
4. 采样率语义：player 模式 `output_sample_rate<=0` 跟随源（Hi-Res 直通）；
5. DSP 顺序不变。

---

## 5. 构建系统：build.zig 与跨平台矩阵

### 5.1 `build.zig` 骨架

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});          // -Dtarget=...
    const optimize = b.standardOptimizeOption(.{});       // -Doptimize=...

    // 1) FFI 共享库（Dart 直连）
    const mediaengine = b.addSharedLibrary(.{
        .name = "archoera_mediaengine",
        .root_source_file = b.path("src/mediaengine.zig"),
        .target = target,
        .optimize = optimize,
    });
    mediaengine.linkLibC();                                // @cImport 需要
    mediaengine.addCSourceFiles(.{
        .files = &.{ "c/miniaudio.c", "c/dr_mp3.c", "c/dr_flac.c" },
        .flags = &.{ "-std=c11", "-O3", "-fno-sanitize=all" },
    });
    mediaengine.addIncludePath(b.path("c"));
    mediaengine.addIncludePath(b.path("include"));
    // vendored libopus（可选开关）
    if (b.option(bool, "opus", "vendor libopus") orelse true) {
        mediaengine.addCSourceFiles(.{ .files = opusSources, .flags = &.{"-O3"} });
    }
    b.installArtifact(mediaengine);

    // 2) CLI 二进制
    const cli = b.addExecutable(.{
        .name = "archoera-audio-engine",
        .root_source_file = b.path("src/cli.zig"),
        .target = target, .optimize = optimize,
    });
    cli.linkLibrary(mediaengine);  // 或复用根模块
    b.installArtifact(cli);

    // 3) libfft.so（独立共享库，Dart fft_bindings 直接加载）
    const fftlib = b.addSharedLibrary(.{
        .name = "fft", .root_source_file = b.path("src/kernel/dsp/fft_abi.zig"),
        .target = target, .optimize = optimize,
    });
    b.installArtifact(fftlib);

    // 4) 测试
    const tests = b.addTest(.{ .root_source_file = b.path("src/kernel/decoder.zig") });
    tests.addCSourceFiles(...);  // 同媒体库的 C 源
    b.step("test", "Run kernel tests").dependOn(&tests.step);
}
```

**格式插件化（P6）在 build.zig 的落地**——特性开关决定 vendored C 源是否编译：

```zig
// 每个格式选项：开启则把对应 vendored C 源加入编译，并把特性常量传给根模块（comptime 裁剪）
const fmt_opts = .{
    "mp3"   => &.{"c/dr_mp3.c"},
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
    if (enabled) mediaengine.addCSourceFiles(.{ .files = fmt_opts[f], .flags = &.{"-O3"} });
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

### 5.3 与既有构建链的关系

| 现状 | 变更 |
|---|---|
| `app/core/audio-engine/CMakeLists.txt` | **删除**，改用 `build.zig` |
| `app/core/audio-engine/rebuild-engine.sh` | 删除（不再有 FFmpeg 自编译） |
| `app/core/audio-engine/build/`（FFmpeg 内嵌库） | 删除 |
| `app/core/build-linux.sh` / `build-macos.sh` / `build_windows.bat` | 收敛为 `zig build` 包装脚本（每平台一条 `zig build -Dtarget=...`） |
| `app/vcpkg.json` | 移除 `ffmpeg`；`opus` 改走 vendored（源码入库），vcpkg 可仅保留 scraper 需要的 taglib/curl/... |
| `.github/workflows/build-*.yml` | 三套 job 统一调 `zig build -Dtarget=...`，Linux job 交叉产出 Windows |

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
- `aborted` 原子标志由所有 `read/seek/peek` 检查（§13 中断）；
- 网络输入：**Dart 预下载临时文件**（同旧方案 §4.3）——引擎只收本地路径，
  内核零网络 / 零 TLS / 零 curl/openssl 依赖（P2 的直接收益之一）。

---

## 7. 格式探测

`kernel/probe.zig`：读前 64 字节（并解析/跳过 ID3v2 头）做魔数嗅探，返回 `Format` 枚举：

| 魔数 / 特征 | Format | 解码模块 |
|---|---|---|
| `OggS` + `OpusHead` | `.ogg_opus` | `fmt/ogg.zig` + `fmt/opus.zig` |
| `OggS` + `vorbis` | `.ogg_vorbis` | `fmt/ogg.zig` + `fmt/vorbis.zig`（T0，Phase D） |
| `fLaC` | `.flac` | `fmt/flac.zig` |
| `RIFF`+`WAVE` / `RIFX` / `RF64` / `w64` / `FORM`+`AIFF` | `.wav` | `fmt/wav.zig` |
| `ID3` 或 MPEG sync（`0xFF Ex/Fx`） | `.mp3` | `fmt/mp3.zig` |
| `ftyp`（box size + brand） | `.m4a` | `fmt/m4a.zig`（AAC / ALAC 由 `moov/atoms` 内 codec 判定） |
| ADTS sync（`0xFF F1/F9`） | `.aac` | `fmt/adts.zig` |
| `MAC ` | `.ape` | `fmt/ape.zig`（T1，许可通过后） |
| `wvpk` | `.wv` | `fmt/wv.zig`（T1） |
| `DSD ` / `FRM8`+`DSD `（dff） / `ID3`+`DSD `（dsf） | `.dsd` | `fmt/dsd.zig`（T1） |
| `#!AMR` / AMR 帧头 | `.amr` | `fmt/amr.zig`（T1，Phase F） |
| `FORM`+`AIFF` 已在 `.wav`（AIFF 是 RIFF 变体） | — | — |
| 其余 | `.unknown` | 返回带原因错误 |

> **M4A 容器内多编解码**：`fmt/m4a.zig` 解析 `moov` 后按音频轨 `stsd` 的 codec 四字符码分发
> （`mp4a.40.2` → AAC、`alac` → ALAC），同一容器模块承载 AAC 与 ALAC（§3.5 容器/编解码分离）。

- `probe` 返回 `error.UnsupportedFormat` 时，`engine.zig` 经 FFI 事件上报 `{"type":"error",...}`；
- 冲突消解：ADTS vs MP3 sync 需二次判定（ADTS 校验 `layer` 位 + 帧长合法性）；
- 未开启的格式开关（§3.6）在 `probe` 中直接判 `unsupported`（不误报"已支持"）。

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
        .mp3  => fmt.mp3.open(&io, info),
        .ogg_opus => fmt.ogg.open(&io, info),
        .m4a  => fmt.m4a.open(&io, info),
        .aac  => fmt.adts.open(&io, info),
        else  => error.UnsupportedFormat,
    };
}
```

- allocator：`engine.zig` 传入（`std.heap.c_allocator` 或自建 GPA），模块不自分配全局状态；
- 无全局变量 / 无静态注册表，天然可多实例并发（转码线程模型与现状一致）。

---

## 9. 各格式实现与依赖账本明细

### 9.1 WAV / AIFF / W64 / RF64 —— 自研 `fmt/wav.zig`

- 解析 `RIFF/RIFX/RF64/W64/FORM` 容器 + `fmt ` chunk（PCM / IEEE float / ADPCM→可拒绝）；
- 输出 s16/s24/s32/f32；`data` 大小 → 精确时长；`seek` 直接定位 `data` 内偏移；
- 覆盖现状 `dr_wav` 的全部容器子集；**纯表解析，自研 ~250 行**。

### 9.2 OGG / Opus —— 自研解复用 `fmt/ogg.zig` + libopus 封装 `fmt/opus.zig`

- `ogg.zig`：OggS 页解析（页头 / lacing / 续页）、`OpusHead` / `OpusTags` 处理、granule→PTS、
  尾页 granule → 精确时长（可先给估算、后台回填）；自研 ~300 行；
- `opus.zig`：vendored libopus（`opus_decoder_create` / `opus_decode_float`）封装；
- **CRC-32 注意**：Ogg 页 CRC 用**非反射** CRC-32（多项式 0x04C11DB7），
  Zig `std.hash.Crc32` 是反射（zlib）变体，需自写 256 项表（§3.2 已列）；
- 备选：`libopusfile`（BSD）仅在自研解复用受阻时引入，`Decoder` 接口隔离，无缝切换。

### 9.3 FLAC —— 自研 `fmt/flac.zig`（目标）；dr_flac 兜底

- 自研要点：`fLaC` 头 → STREAMINFO（block/采样率/声道/总样本 → 精确时长）→ 帧（frame header +
  SUBFRAME 定长/线性预测/LPC + 残差 Rice 解码 + 校验）+ seek 表；~2500 行；
- 自研完成前：`fmt/flac.zig` 内部走 vendored `dr_flac`（单文件 C，MIT-0/PD，源码入库），
  接口一致，上线后无缝切换（P2：能自研就自研）。

### 9.4 MP3 —— vendored `dr_mp3`（单文件 C，MIT-0 / PD）

- `fmt/mp3.zig`：`@cImport("dr_mp3.h")` 调用 `drmp3_*`；
- **首遍索引**：桌面播放/转码首遍顺序解析帧头（帧长→累计样本），构建 `sample→file_offset` 稀疏表
  （每 ~1s 锚点），供 `seek_ms` 二分 + 帧同步重入；XING/Info 头存在时直接利用（§12.3）；
- 自研 MP3（Layer III）成本 ≈5000+ 行（IMDCT/霍夫曼/滤波器组/联合立体声），判定不可行，
  依 §3.3 规则 vendored dr_mp3。

### 9.5 AAC / M4A —— 自研解复用 + vendored OpenCORE（P1，可降级）

- `fmt/m4a.zig`（自研 ~700 行）：只解析**音频轨**（`mp4a`），`moov/mvhd` → 时长，
  `stbl/stco/stsc/stsz/stts` → 样本表 → 精确 seek；**视频轨（avc1/hev1 等）跳过**（P4）；
- `fmt/adts.zig`（自研 ~150 行）：ADTS 帧头 + 帧长；
- 解码：vendored **OpenCORE AAC**（Apache-2.0）`aacDecoder_DecodeFrame`；
- **降级策略（AAC 引入受阻不阻塞发布）**：
  - `build.zig` 开关 `-Dopus=true -Daac=false`；关闭时 `m4a/adts` 返回 `error.UnsupportedFormat`；
  - 平台侧：网易云/酷狗/QQ 优先请求 mp3/flac 音源（QQ 音乐 m4a → mp3）；
  - 本地 m4a/aac 未支持时 UI 明确提示。

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

> 决策（2026-08-15）：输出层升级为自研目标（§3.7）——这是消除最后一个 C 依赖、
> 让整个内核 100% Zig/自研的关键一步，也最能体现 P1 跨平台掌控力。设计见 §15。

- `kernel/device.zig`：跨平台设备抽象（打开/播放/暂停/seek/音量/位置），每平台一个后端；
- 过渡期 `player.zig` 仍可 `@cImport("miniaudio.h")` 编译（`c/miniaudio.c` 唯一实例化点），
  `device.zig` 完成后替换，接口层一致；
- 跨平台边界说明见 §15（Linux ALSA/Pulse/PipeWire、Windows WASAPI、macOS CoreAudio）。

### 9.8 ALAC（M4A 内无损） —— **自研 Zig**（目标）；`alac.c` 兜底

> 决策（2026-08-15）：ALAC 与 FLAC/APE 同类（无损、可 bit-exact 校验、有参考实现），
> 升级为自研目标（§3.7）。

- 算法：帧内自适应线性预测（中值预测 + 系数更新）+ Rice 风格残差熵编码 + 多声道整形
  （`element` 组合 / 交错）；~1800 行；
- 复用 `fmt/m4a.zig` 容器（`stsd` 内 `alac` codec 分发，§7），**只加解码器、不动容器**；
- **验证闭环**：Apple 参考 `alac.c`（Apache-2.0，作对照不引入运行时）输出 bit-exact 比对；
  黄金文件（mono/stereo/多声道 × 16/20/24bit）；
- 兜底：`alac.c`（单文件 C，Apache-2.0）编译进内核，接口隔离无缝切换。

### 9.9 WavPack（.wv） —— **自研 Zig**（目标）；libwavpack 兜底

> 决策（2026-08-15）：WavPack 支持无损模式，可 bit-exact 校验，升级为自研目标（§3.7）。

- 容器：`wvpk` 头 + block 解析自研（~150 行）；
- 解码：块内预测（自适应 FIR/IIR + 去相关矩阵）+ Rice 残差熵编码 + 混合模式（浮点/有损修正）；~2500 行；
- **验证闭环**：libwavpack（BSD-3，作对照）输出 bit-exact 比对；黄金文件（无损/混合 × mono/stereo/5.1 × 16/24/32bit float）；
- 兜底：vendored `libwavpack`（BSD-3-Clause，源码入库）`WavpackUnpackSamples`；
- 混合有损模式的 `.wvc` 修正文件为加分项，不做承诺。

### 9.10 APE（Monkey's Audio） —— **全自研解码器**

> 决策（2026-08-15）：APE 能力**自研实现**，不再依赖 Monkey's Audio 官方 SDK，
> 彻底消除 §20 的许可证阻塞项，符合 P2"能自研就自研"。无损解码可 **bit-exact 校验**，
> 验证闭环优于有损编解码。

**算法构成（自研分解）**：

| 组件 | 说明 | 自研量 |
|---|---|---|
| 容器/帧 | `MAC ` 魔数 + 描述符（版本/压缩级别/声道/采样率）+ 帧表 + 帧头（CRC/存储位数/range 缩减） | ~200 行 |
| **range coder**（区间算术编码器） | 无乘法区间编码 + 按压缩级别分支的位模型；解出残差 | ~150 行 |
| **多预测器（Predictor Compressor）** | 核心难点：`comp_level` 决定预测器数量（fast=2 / normal=4 / high=8 / extra=16 / insane=32）；每个预测器是一组自适应 FIR 系数 + **Monkey's Audio 特有的逐样本更新规则**（`m_da`/`m_db` 字节对齐更新），必须逐位复刻才能无损解码 | ~600 行 |
| **立体声去相关** | mid/side 变换 + "第二滤波器"（版本相关） | ~200 行 |
| 版本差异 | 3.80~3.99 / 4.x 的帧粒度、滤波器与预测器细节不同 | 适配 ~300 行 |

合计 **~1200~1500 行 Zig**，复杂度和 FLAC 自研相当，属内核中第二重的自研编解码。

**验证闭环（bit-exact，这是无损的优势）**：

1. **黄金文件**：固定压缩级别 × 声道 × 采样率（fast/normal/high/extra high/insane × mono/stereo × 44.1k/96k）
   的 `.ape` 样本，期望输出 PCM **bit-exact 匹配**（逐样本 `==`）；
2. **对照参考**：迁移期现有 C 引擎（FFmpeg 内置 APE 解码 `apedec.c`）输出 `-f f32le`，
   与自研输出逐样本比对——FFmpeg 本身就是最完整的参考实现；
3. **CRC 校验**：APE 帧头自带 CRC，解码后回算比对，可定位错误帧；
4. 上线后 `-Dape=true` 默认开启；实现完成前保持 `-Dape=false`（probe 判 unsupported，不误报）。

**风险控制**：

- 预测器更新规则复刻不精确 → 解码错乱：靠 bit-exact 校验快速定位 + FFmpeg 参考逐函数对照；
- 冷门版本（3.8x 老版）可先只支持 3.98+ 主流版本，其余明确报 `UnsupportedFormat`（版本字段可判）;
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

### 9.13 AMR（.amr / 3GP 音频） —— 自研容器 + vendored OpenCORE AMR（Apache-2.0，Phase F）

- `#!AMR` 头 + 帧重同步自研（~100 行）；解码走 OpenCORE AMR-NB/WB（Apache-2.0）；
- 低频格式，仅 Phase F 按需开启。

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
| MP3 CBR | 文件大小 / 比特率 | estimate（可 exact） |
| MP3 VBR | XING/Info 头（存在时） | estimate |
| MP3 VBR（无头） / ADTS | 首遍全扫建索引 | 首遍后 exact |
| MP3 VBR（无头） / ADTS | 首遍全扫建索引 | 首遍后 exact |

### 12.2 位置跟踪

- `Decoder.position_ms()`（累计 read 输出样本）替代现状 `resampler_get_output_samples`；
- `start_offset_ms`（CUE）：`seek_ms(offset)` 后计数，语义一致。

### 12.3 MP3 seek（已知短板，专项）

- dr_mp3 无帧级 seek API → `fmt/mp3.zig` 内置**首遍索引**（§9.4）；
- XING/Info 头 → 直接利用其帧数/字节表，免全扫；
- 批量模式（不 seek）经 `Info` 提示关闭索引。

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
- 解析器所有长度字段校验 `<= 输入大小`，循环有界（页数/帧数上限），防 zip-bomb/畸形文件 DoS。

---

## 14. DSP 移植与 libfft.so（保持 Dart ABI）

- `equalizer/loudness/limiter/fft` 四个 DSP 模块把现状 C 实现**逐函数移植到 Zig**
  （现有 C 共 ~1200 行，语义对照移植，配套测试直接复用 `tests/test_equalizer.c` 等黄金断言）；
- `libfft.so` 的 Dart ABI 必须保持不变：`fft_create/fft_set_enabled/fft_process_multi/
  fft_get_spectrum_norm_stereo/...` 以 `export fn ... callconv(.C)` 从 `dsp/fft_abi.zig` 导出，
  `fft_bindings.dart` **零改动**；
- 移植期可选：先让 Zig 内核 `@cImport` 编译现有 `fft.c/equalizer.c`（C 源临时保留），
  再逐模块替换为 Zig 实现，降低一次性移植风险。

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

- 自研 device 未完成的后端/平台，`player.zig` 退回到 `@cImport("miniaudio.h")` 编译
  （`c/miniaudio.c` 唯一实例化点）；`device.zig` 接口与它对齐，替换对上层零感知；
- **移除路径**：三平台后端全部验收后，删除 `c/miniaudio.*` 与 `@cImport` 分支——
  内核 100% Zig/自研（P2 完全达成）。

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

## 16. FFI 边界与 CLI

### 16.1 `mediaengine.zig`（替代 mediaengine_lib.c）

```zig
export fn archoera_mediaengine_create(
    source: [*:0]const u8,
    cfg: *const EngineConfig,
    player_file: ?[*:0]const u8,
    session_dir: [*:0]const u8,
    errbuf: ?[*]u8, errbuf_size: usize,
) callconv(.C) ?*ArchoeraMediaEngine { ... }

export fn archoera_mediaengine_command(e: ?*ArchoeraMediaEngine, json_line: [*:0]const u8) callconv(.C) c_int { ... }
export fn archoera_mediaengine_poll_event(e: ?*ArchoeraMediaEngine, buf: [*]u8, cap: usize) callconv(.C) c_int { ... }
export fn archoera_mediaengine_session_dir(e: ?*ArchoeraMediaEngine) callconv(.C) [*:0]const u8 { ... }
export fn archoera_mediaengine_is_done(e: ?*ArchoeraMediaEngine) callconv(.C) c_int { ... }
export fn archoera_mediaengine_destroy(e: ?*ArchoeraMediaEngine) callconv(.C) void { ... }
```

- 线程模型不变：创建时 `std.Thread.spawn` 启动引擎线程（转码 + miniaudio 播放），
  事件 FIFO（`std.Mutex` + 环形缓冲）与命令 FIFO 照搬现状语义；
- `EngineConfig` 以 C 结构体布局导入（`extern struct`，与 `audio_engine.h` 对齐）；
- `include/archoera_mediaengine.h` 保留作契约声明，`@cImport` 编译校验 ABI 一致性；
- **Dart 侧 `engine_bindings.dart` / `audio_engine_process.dart` 零改动**；
  Dart 仅新增"在线源预下载临时文件"一步（§6）。

### 16.2 `cli.zig`（替代 main.c）

- 保留全部现状 CLI 参数与 UDS 语义（`--interactive/--control-uds/--pcm-uds/--stream-uds/
  --player-file/--eq/--tempo...`）；
- `std.process.argsAlloc` + `std.getopts`（Zig 0.13+）替代 `getopt_long`；
- SIGTERM → `Reader.abort()` + 优雅退出，UDS 生命周期与现状一致。

---

## 17. 测试与验证

### 17.1 单元测试（`zig build test`）

- `tests/` 每格式黄金文件（MP3/FLAC/OGG-OPUS/WAV/M4A **+ T1：ALAC/WavPack/DSD/AIFF/Vorbis** 小样本）
  + 输出 PCM **MD5/SHA256 校验**；
- `probe.zig` 全表 + 混淆用例（ADTS vs MP3）；每个格式开关各编译一遍确认裁剪正确（`-Dape=false` 时 probe 判 unsupported）；
- `pcm/*` 逐样本校验 + 误差界；`ogg_muxer.zig` 输出可被 `opusinfo` / 系统播放器打开；
- DSP 移植：复用现状 `tests/test_equalizer.c` 等的黄金断言（移植为 Zig test）。

### 17.2 一致性对比（迁移护栏，对齐旧方案 §13.2）

- 迁移期保留现状 C 引擎产物作**对照 target**（不进发布）；
- 同一输入分别经两内核转码 float32 WAV：无 DSP 路径 `MAX_DIFF < 1e-4`（float）或逐样本 bit-exact（int）；
  有 DSP 路径用响度/频谱统计断言；
- 退出条件：三平台核心格式全部通过后删除对照 target。

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
| `app/core/audio-engine/` | C 源迁往 `legacy/`（过渡对照 target），Zig 工程落地根目录；对照通过后删除 |
| `CMakeLists.txt` / `rebuild-engine.sh` / `build/ffmpeg/` | 删除 |
| `app/core/build-linux.sh` / `build-macos.sh` / `build_windows.bat` | 收敛为 `zig build -Dtarget=<三平台>` 包装 |
| `app/vcpkg.json` | 移除 `ffmpeg`；`opus` 走 vendored（源码入库）；vcpkg 仅保留 scraper 的 taglib/curl/openssl/sqlite3 等 |
| `.github/workflows/build-*.yml` | 统一 `zig build -Dtarget=...`；Linux job 交叉产出 Windows；macOS job 全量构建 |
| `app/linux|windows|macos/CMakeLists.txt` | 产物改名保持（`libarchoera_mediaengine.so/.dll/.dylib`、`libfft.so`、`archoera-audio-engine`），`native/` 平铺布局不变 |
| bundle 体积 | 移除 FFmpeg 运行库（Linux 内嵌 ~几十 MB）显著下降；新增 vendored libopus（~1MB） |
| 打包（`packaging/linux/` 等） | `native/` 布局与文件名不变，逻辑零改动 |

---

## 19. 分阶段实施路线

| 阶段 | 内容 | 出口标准 |
|---|---|---|
| **Phase A** Zig 工程骨架 + 内核核心 | `build.zig` 落地（三平台 target）；`kernel/io.zig` `probe.zig` `decoder.zig` `pcm/*`；`fmt/wav.zig`（自研）；DSP 移植为 Zig；`mediaengine.zig` 导出 FFI（先 `@cImport` 复用现有 C 解码源临时过渡） | 本地 wav 播放 + FFT + DSP 回归；`engine_bindings.dart` 零改动跑通；三平台 target 构建通过 |
| **Phase B** FLAC / MP3 / OGG-Opus | `fmt/flac.zig`（自研，dr_flac 兜底）、`fmt/mp3.zig`（dr_mp3 + 首遍索引）、`fmt/ogg.zig` + `fmt/opus.zig`（vendored libopus）；`encode/*`（libopus + 自研 OGG mux） | 本地 flac/mp3/ogg/wav 播放 + seek + FFT；在线 mp3/flac 播放；CLI 批量 OGG/Opus 输出 |
| **Phase C** AAC / M4A | `fmt/m4a.zig` `fmt/adts.zig`（自研）+ vendored OpenCORE；`-Daac=false` 降级开关 | 本地/在线 m4a/aac 播放；未支持源明确错误 |
| **Phase D** T1 无损收藏 | **WavPack**（`fmt/wv.zig` 自研，libwavpack 兜底）、**ALAC**（自研，alac.c 兜底）、**APE**（`fmt/ape.zig` 自研解码器，§9.10）、**DSD**（`fmt/dsd.zig` 自研 DSF/DFF→PCM）、**AIFF**（并入 wav.zig）、**Vorbis**（vendored stb_vorbis） | 本地 wv/alac/dsd/ape/aiff/vorbis 播放 + seek + FFT；APE/ALAC/WavPack bit-exact 校验全绿 |
| **Phase E** 输出层 + 变速自研 | **`kernel/device.zig`**：先 Linux（ALSA/Pulse 动态加载）→ Windows WASAPI → macOS CoreAudio（§15）；**WSOLA 变速**（`kernel/tempo.zig` 自研，tempo-rs 对照）；逐步移除 miniaudio / tempo-rs | 三平台真机出声 + 位置事件正确；tempo A/B 主观 + 客观对照通过；`c/miniaudio.*` 与 Rust 依赖删除（100% Zig/自研） |
| **Phase F** 收尾 + 长尾 | 移除全部 FFmpeg 残留（CMake/vcpkg/CI/脚本/文档）；对照 target 删除；`THIRD-PARTY-LICENSES.md` 按开关登记；设置页显示已编译解码器清单；可选 AMR/WMA/MP2 按 §3.3 规则评估 | 三平台 `ldd`/`dumpbin` 无任何 `libav*`/`libsw*`；`zig build test` 全绿；各格式开关独立可裁剪 |

---

## 20. 风险与决策点

| 风险/决策 | 说明 | 对策 |
|---|---|---|
| **FLAC 自研复杂度** | 无损解码（LPC/Rice/校验）~2500 行 | 目标自研；dr_flac（MIT-0/PD，单文件）兜底，`fmt/flac.zig` 接口隔离无缝切换 |
| **ALAC 自研复杂度** | 自适应预测 + Rice 熵编码 ~1800 行 | §9.8：Apple `alac.c`（Apache-2.0）对照 bit-exact 校验；兜底 alac.c |
| **WavPack 自研复杂度** | 块内预测/去相关 + Rice ~2500 行 | §9.9：libwavpack（BSD）对照 bit-exact 校验；兜底 libwavpack |
| **MP3 seek/时长精度** | dr_mp3 无索引；VBR 无 XING 头 | 首遍索引（桌面主流程伴随）；XING 优先；`duration_known` 分级 |
| **AAC 集成** | OpenCORE 代码老、构建适配、HE-AAC | P1 才做；`-Daac=false` 降级不阻塞；平台侧优先请求 mp3/flac |
| **APE 自研复杂度** | range coder + 多预测器（~1500 行），预测器更新规则须逐位复刻 | §9.10：bit-exact 黄金文件 + FFmpeg `apedec.c` 对照 + 帧 CRC 三重校验；实现完成前 `-Dape=false`；极端失败才考虑 §3.3 vendored 回退（许可另行审查） |
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
| **Web 兼容路径存废** | 桌面不编码 | Phase A 临时禁用；确认废弃则删 `encode/` |

---

## 21. 决策记录

1. **语言：Zig**（`build.zig` 单一构建系统 + 交叉编译 + freestanding + `@cImport`），替代 C + CMake + 三平台脚本。
2. **跨平台优先（P1）**：内核核心零平台差异、可任意宿主交叉编译；平台差异仅存在于输出层（macOS 需 SDK，
   由 macOS CI job 全量构建；Linux/Windows 交叉/本地构建）。
3. **自研优先（P2，2026-08-15 强化）**：容器/采样/DSP/封装/输出层全部自研 Zig；无损编解码
   （FLAC/APE/ALAC/WavPack）自研并 bit-exact 校验；仅 MP3/Opus/AAC 因数学复杂度不可自研而
   vendored（Permissive 单文件或源码入库，零构建期下载）。裁决见 §3.7。
4. **依赖账本（最终形态）**：自研=WAV/AIFF/OGG/MP4/ADTS/DSF/DFF/WV 容器 + 采样三件套/DSP/OGG 封装/
   DSD→PCM + **FLAC/APE/ALAC/WavPack 解码器** + **device.zig 输出层** + **WSOLA 变速**；
   vendored 单文件=dr_mp3（MP3）+ stb_vorbis（Vorbis）+ miniaudio（输出过渡兜底）+ dr_flac/alac.c/
   libwavpack（各自研兜底）；
   vendored 源码=libopus（Opus，唯一正式库）+ OpenCORE（AAC，P1）；
   tempo-rs（Rust）仅作 WSOLA 过渡兜底。
   **不引入**：FFmpeg / faad2 / libfdk-aac / WMA（生态待评估）。
5. **零 FFmpeg（P3）**：不链接任何 `libav*` / `libsw*`；视频解码不做、不支持（P4）。
6. **行为兼容（P5）**：`archoera_mediaengine.h` 导出符号与 JSON 协议、`libfft.so` Dart ABI、
   `stream.wav`/`stream.pcm` 落盘格式不变；Dart 侧仅新增"在线源预下载临时文件"。
7. **解码器统一接口 `kernel/decoder.zig`**：输出原生位深交错 PCM，采样转换由
   `convert + downmix + resampler（多相 FIR）` 三件套处理。
8. **格式插件化（P6）**：comptime 特性开关逐格式编译/裁剪，默认只含 T0；未开格式 probe 判 unsupported；
   每格式独立许可审查并登记 `THIRD-PARTY-LICENSES.md`。
9. **时长/seek 分级**：exact/estimate/unknown；MP3 首遍索引 + XING；Opus 尾页回填。
10. **中断**：`Reader.abort()` 原子标志替代 AVIOInterruptCB；Zig error set 统一错误模型。
11. **许可合规**：新引入仅限 MIT-0/PD/BSD-3/Apache-2.0，逐一登记 `THIRD-PARTY-LICENSES.md`；
    **APE 解码器全自研（AGPL）**，不依赖 Monkey's Audio 官方 SDK，无许可阻塞。
12. **自研扩张原则（2026-08-15）**：凡"无损可 bit-exact 校验 + 有参考实现"的编解码器一律自研
    （FLAC/APE/ALAC/WavPack）；输出层与变速变调亦自研（device.zig / WSOLA）；miniaudio、tempo-rs、
    dr_flac、alac.c、libwavpack 仅作过渡/兜底，自研验收后移除。最终内核 100% Zig/自研，
    仅 libopus（Opus 编解码）一个外部库。
