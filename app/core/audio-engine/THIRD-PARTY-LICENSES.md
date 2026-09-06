# 音频引擎第三方许可证声明（audio-engine / C 引擎 + Zig 内核）

本目录 `app/core/audio-engine` 为 ArchoeraMusic 的音频引擎（FFmpeg 解码 +
miniaudio 播放 + Rust tempo + Zig 解码内核）。其**自研代码**随本软件以 AGPL-3.0 授权；
第三方组件按各自许可使用，逐项登记见下。

> 架构调整（2026-08-16，见 `docs/audio-kernel-zig.md`）：**FFmpeg 保持默认主解码引擎**
> （`-Duse-ffmpeg` 默认开启，行为零回归），Zig 内核逐格式验收后按格式接管（格式级开关），
> 全部 T0/T1 接管后可选 `-Dzig-main=true` 升主，**默认仍 FFmpeg**。
> 本文档第一部分反映**现状 C 引擎**；第二部分自 2026-09 起按 Zig 内核实际
> 使用面逐格式登记第三方来源（vendored 源码 / 移植 / 转录 / 对照重构）。

## 合规说明与分发义务（重要）

- **授权结构**：本引擎的**自研代码**以 AGPL-3.0 发布；各第三方组件按**各自许可**继续适用
  （下述表格逐项登记）。整体作为 AGPL-3.0 聚合作品分发时，只并入与 AGPL-3.0 兼容的组件，
  且逐一满足其许可条款。
- **静态链接的 LGPL 部分**：除 FFmpeg 为动态链接外，Zig 内核把若干 **LGPL-2.1+ 衍生/移植**
  文件**静态编译**进 `libarchoera_kernel`。因此不仅提供源码，还需满足 LGPL 对静态组合的
  「可重链 / 对应源码」要求——本仓库随发**完整内核源码与构建链**
  （`app/core/build-linux.sh`、audio-engine `CMakeLists.txt` + `build.zig`），任何人可
  修改 LGPL 部分并重编译替换；如需 relink 用目标文件，可联系维护者提供。
- **上游许可优先**：本表以项目维护者对上游许可的理解整理，**不构成法律意见**；正式依据以上游
  各项目官方许可文本为准，若有出入请以其为准。
- **GPL 防火墙**：AGPL-3.0 与 GPL-2.0-only 不可合并分发。内核只允许出现 LGPL-2.1+ / BSD /
  MIT / Apache-2.0 / CC0 / PD 来源（详见下文「GPL 风险提示」），禁止直接并入任何 GPL 系
  （尤其 GPL-2.0-only）参考实现源码。

## 直接依赖

| 组件 | 版本 | 许可证 | 说明 |
|---|---|---|---|
| **FFmpeg**（libavformat/libavcodec/libavutil/libswresample） | 构建时锁定（Linux 内嵌运行库） | LGPL-2.1+（纯 LGPL 构建，无 GPL/nonfree） | 解码 / 重采样（`swr_convert`）。Linux/macOS 经 pkg-config 动态链接，运行库内嵌 `build/ffmpeg/`（RUNPATH=$ORIGIN 解耦系统 major bump）；Windows 经 vcpkg 由 `build_windows.bat` 构建 |
| `miniaudio` | v0.11.25 | MIT-0 / 公有领域（Public Domain）双许可 | 跨平台音频输出（ALSA/PulseAudio/PipeWire/WASAPI/CoreAudio），`include/miniaudio.h` 单头文件 |
| `signalsmith-stretch` | 0.1.3 | MIT | 变速变调（经 `tempo-rs` Rust staticlib `libaudio_tempo.a` 封装） |

## Rust tempo 静态链接说明

- `tempo-rs`（crate 名 `audio-tempo`，`staticlib`）以静态库形式链接进
  `archoera-audio-engine` / `archoera_mediaengine`，随附 C++ 运行时（`stdc++`/`c++`）；
- 其唯一依赖 `signalsmith-stretch` 为 MIT 许可，与 AGPL-3.0 兼容；
- 构建期需要 Rust 工具链（cargo）；构建环境不可用时 tempo 功能降级关闭（`HAS_TEMPO=0`）。

## FFmpeg 特别声明（LGPL，动态链接）

FFmpeg 以**动态库**形式链接（未静态合并），经构建配置确认所用为**纯 LGPL 构建**
（`CONFIG_GPL=0`、`CONFIG_NONFREE=0`），未启用任何 GPL/nonfree 外部编解码库。

依据 LGPL-2.1，使用者享有以下权利：

1. 获得 FFmpeg 对应源代码的自由（官方：https://ffmpeg.org/ ）；
2. 以修改后的 FFmpeg 库替换运行时内嵌库（`native/` 下的 `libav*`）重新分发。

本仓库已随源码提供 FFmpeg 的使用/构建配置（`CMakeLists.txt`、`build_windows.bat`），
满足 LGPL「可替换/可重链」要求。

## 自写播放器（miniaudio）

播放器输出设备使用 `miniaudio`（单头文件 `include/miniaudio.h`，唯一实例化点
`src/player.c`）：

- MIT-0 许可证文本见 `include/miniaudio.h` 文件头；
- 播放链路整体为 FFmpeg(LGPL，动态) + miniaudio(MIT-0/PD) + signalsmith-stretch(MIT)
  + 自研 C 代码，均与 AGPL-3.0 兼容。

## Zig 解码内核第三方声明（`kernel/`）

Zig 内核（`app/core/audio-engine/kernel/`，构建产物 `libarchoera_kernel`）中**确属本项目
独立编写的文件**以 AGPL-3.0 分发；vendored / 移植 / 转录 / 参考对照实现的文件**按各自原许可**
适用（许可保留与溯源登记见下）。内核来源按实现方式分三类登记：

- **Vendored 源码**：第三方完整源码按原许可随内核编译，保留全部版权/许可声明；
- **移植/转录**：以 FFmpeg（LGPL-2.1+）或 libopus（BSD-3-Clause）文件为唯一参考
  的**衍生作品**，保留原许可义务（原许可声明随发 + 对应源码可得）；
- **对照参考实现**：按格式规范 / 标准 / 参考实现行为编写的实现。本文档只作**溯源与许可登记**，
  不在此断言是否构成对参考实现的衍生作品；是否衍生由适用法律与原许可最终判定。若日后被认定
  构成衍生，将按参考源许可补登记并履行相应义务，当前以本文档登记为准。

协议适用约定：内核中不同来源代码**按各自许可分别适用**，不因整体采用 AGPL-3.0 而改变第三方
代码的原许可义务。LGPL-2.1-or-later 部分对收受方允许其按 LGPL v2.1 或任何后续 LGPL 版本
行使权利；本项目对这类静态合并的 LGPL 部分持续履行「保留许可声明 + 对应源码随发 + 可重链」。

### Vendored 第三方源码（编译进内核）

| 组件 | 版本/来源 | 许可证 | 内核位置 | 用途 |
|---|---|---|---|---|
| **stb_vorbis**（Sean Barrett 等） | v1.22，nothings.org | 公有领域（Public Domain，附 MIT-0 备选） | `kernel/c/stb_vorbis.c/.h` | Ogg Vorbis（T0，`fmt/vorbis`），Vorbis 头内嵌声明区与文件尾许可证文本 |
| **OpenCORE / PV-AMR（AMR-NB）** | OpenCORE / Android pvgsmamr + Martin Storsjo OSCL shim（2009） | Apache-2.0 | `kernel/c/amr/**` | AMR-NB（T1，`fmt/amr`，`-x c` 编译），`oscl/*.h` 文件头含完整 Apache-2.0 文本 |

### 移植 / 转录（FFmpeg `libavcodec`/`libavformat` → 衍生作品，LGPL-2.1+）

按文件头标注的「逐句 / 逐位 / 逐函数 / bit-exact 移植」归类，参考版本 FFmpeg n9.0.1：

| 模块 | 内核位置 | 参考文件 |
|---|---|---|
| WMA v1/v2 | `fmt/wma/wmadec.zig` | `wmadec.c` + `wma.c` |
| WMA 容器 | `fmt/wma/packets.zig` | `asfdec_f.c`（最小移植，单音频流） |
| WMA Pro | `fmt/wma/wmapro/core.zig` | `wmaprodec.c`（逐函数） |
| WMA Lossless | `fmt/wma/wmalossless/core.zig` | `wmalosslessdec.c`（逐函数）+ `put_bits.h` |
| WMA Voice | `fmt/wma/wmavoice/*` | `wmavoice.c` / `celp_filters.c` / `acelp_filters.c` / `av_tx`（逐位复刻） |
| AAC SBR | `fmt/aac/sbr.zig`、`sbr_huff.zig`、`mdct.zig` | SBR 浮点路径 bit-exact 移植；`av_tx` 黄金向量对照 |
| AAC LATM/LOAS | `fmt/latm.zig` | `aacdec_latm.h`（对照参考实现） |
| AC-3 | `fmt/ac3/mantissa.zig`、`downmix.zig` | `ac3dec.c`（移植函数，唯一参考源）；`tables.zig` 表值取自 ATSC A/52 规范与 FFmpeg 表 |
| ALS | `fmt/als/core.zig` | `alsdec.c` + `bgmc.c`（逐位移植） |
| AMR-WB | `fmt/amrwb/*`（codec/tables/dsp） | `amrwbdec.c` 浮点路径逐句移植（自有 Zig 浮点实现，非 OpenCORE 代码） |
| Musepack | `fmt/mpc/{sv7,sv8,synth,vlc}.zig` | `mpc7.c` / `mpc8.c` / `mpc.c` + `mpegaudiodsp` 固定点（逐句/逐位复刻） |
| Speex | `fmt/spx/lib.zig`、`data.zig` | `speexdec.c` 对照移植 + `speexdata.h` 逐值转录（码本） |
| DST/DSD | `fmt/dst/dst.zig`、`fmt/dsd.zig` | `dstdec.c` 逐句移植；`dsd.c` 对照 |
| Opus 表 | `fmt/opus/celt_tables.zig` | `libavcodec/opus/tab.c`（表值提取，本源 libopus） |
| TTA | `fmt/tta/core.zig` | `tta.c`（逐句对齐 FFmpeg n9.0.1） |
| TAK | `fmt/tak/{core,lib,tables}.zig` | `takdec.c` + `tak.c`（逐句对齐 FFmpeg n9.0.1） |
| Shorten | `fmt/shn/core.zig` | `shorten.c`（逐句对齐 FFmpeg n9.0.1） |

### 移植 / 依赖（libopus → 衍生作品，BSD-3-Clause，IETF RFC 6716 参考实现）

| 模块 | 内核位置 | 参考文件 |
|---|---|---|
| SILK 解码器 | `fmt/opus/silk.zig` | libopus 1.6.1 `silk/`（固定点移植，含 CNG/PLC） |
| CELT FFT/MDCT | `fmt/opus/kissfft.zig` | libopus `celt/kiss_fft.c` + `celt/mdct.c`（`kiss_fft` 本源为 Mark Borgerding BSD-3-Clause） |
| 静态模式表 | `fmt/opus/static_tables.zig` | libopus 1.6.1 `static_modes_float.h`（自动生成） |

### BSD 系（各原作者）

| 组件 | 许可证 | 内核位置 | 说明 |
|---|---|---|---|
| **WavPack**（David Bryant 等） | BSD-3-Clause | `fmt/wv/*` | 参考对照 `wavpack.c/h`、`wavpackdata.c`（对照参考实现） |
| **dsd2pcm**（Sebastian Gesemann） | BSD | `fmt/dsd.zig` | 常量/算法来源，`dsd.c` 即基于其 BSD dsd2pcm |

### CC0 / 公有领域

| 组件 | 许可证 | 内核位置 | 说明 |
|---|---|---|---|
| **minimp3**（lieff） | CC0 | `fmt/mp3/layer3_tables.zig`、`huffman_tables.zig` | Layer III 解码表自 minimp3 转录；seek 语义对齐 minimp3 |

### 对照参考实现（溯源登记）

以下模块为实现时对照参考实现/规范编写，参考对象仅用于溯源与行为对齐；是否构成对参考实现的
衍生作品由适用法律与原许可最终判定，本文档不作绝对结论，以逐项登记为准：
FLAC（`flacdec.c`/`flacdsp_template.c`）、DTS、MLP/TrueHD（`mlpdec.c`）、
MP3 Layer I/II/III 码流层（`mp3dec.c`）、APE（`apedec.c`/`ape.c`）、ALAC（FFmpeg `alac.c`
仅对照、未并入其运行时实现；Apple 参考 alac.c（Apache-2.0）同属对照）、Ogg/M4A 容器、OPUS
CELT/PVQ/RangeCoder/打包（对照 FFmpeg `celt.c`/`pvq.c`/`rc.c` 与 libopus `entdec.c`）。

### GPL 风险提示（务必遵守）

TTA / TAK / Shorten 的**官方/原生参考实现**为 GPL 系（TTALib GPL-2.0、TAK Solution 参考实现
GPL-2.0、SoftSound shorten GPL），**不得直接转录/引用其源码**。内核中这三类格式的实现均沿
**FFmpeg（LGPL-2.1+）通道**逐句对齐（见上文移植表，属 LGPL-2.1+ 衍生登记），禁止改换到官方
GPL 参考源；后续若需变更实现方式，应先做许可评估。任何 GPL 系参考源码（含 GPL-2.0-only）
一律不得并入 Zig 内核或本引擎。

## 合规评估与义务清单

以下为项目维护者的合理努力评估（非法律意见）：

- **来源构成**：FFmpeg 动态链接（纯 LGPL-2.1+ 构建）；Zig 内核 = 自研 AGPL + vendored
  PD/Apache-2.0 + LGPL-2.1+ 移植（FFmpeg 通道）+ BSD-3-Clause（libopus/WavPack 等）+
  CC0/PD（minimp3/stb_vorbis 等）+ MIT/Apache 依赖，**无已知** GPL 系或未许可源码并入
  （如有出入欢迎指正）。
- **AGPL 聚合作品可分发**：上述许可按各自条款可与 AGPL 代码共存
  （LGPL-2.1+ 部分按上文「合规说明与分发义务」满足源码/重链/声明要求）。
- **持续义务**：随源随发各第三方许可文本与归属声明；公开构建链以便重链；文件头保留来源与
  许可标注；引入新第三方时先按本清单审核再并入；若个别来源分类日后被认定有误，据此修正登记。

---
AGPL-3.0 完整文本见仓库根 `LICENSE`；第三方声明总览见根 `THIRD-PARTY-NOTICES.md`。
