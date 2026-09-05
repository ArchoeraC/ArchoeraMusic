# 音频引擎第三方许可证声明（audio-engine / C 引擎）

本目录 `app/core/audio-engine` 为 ArchoeraMusic 的 C 音频引擎（FFmpeg 解码 +
miniaudio 播放 + Rust tempo），随本软件以 AGPL-3.0 授权。

> 架构调整（2026-08-16，见 `docs/audio-kernel-zig.md`）：**FFmpeg 保持默认主解码引擎**
> （`-Duse-ffmpeg` 默认开启，行为零回归），Zig 内核逐格式验收后按格式接管（格式级开关），
> 全部 T0/T1 接管后可选 `-Dzig-main=true` 升主，**默认仍 FFmpeg**。
> 本文档当前反映**现状 C 引擎**；Zig 逐格式接管后按格式开关补充登记。

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

## 许可兼容性结论

FFmpeg（LGPL-2.1+，动态链接）与本软件全部 MIT/Apache 依赖均兼容 AGPL-3.0；
本音频引擎整体作为 AGPL-3.0 受保护作品的一部分分发，合规。

---
AGPL-3.0 完整文本见仓库根 `LICENSE`；第三方声明总览见根 `THIRD-PARTY-NOTICES.md`。
