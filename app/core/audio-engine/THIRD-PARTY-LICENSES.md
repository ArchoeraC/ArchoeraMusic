# 服务端音频引擎第三方许可证声明（audio-engine / Rust）

本目录 `server/audio-engine` 为 SPlayer-Next 服务端侧的 Rust 音频引擎，
随本软件以 AGPL-3.0 授权，其静态链接 **FFmpeg**（LGPL 构建）。

## 直接 Rust 依赖

| 组件 | 版本 | 许可证 | 说明 |
|---|---|---|---|
| `ffmpeg_audio` | git tag v3.0.0 | 随上游（LGPL FFmpeg 封装） | 静态链接 FFmpeg |
| `ureq` | 2 | MIT | HTTP 客户端（rustls TLS） |
| `rodio` | 0.20 | MIT / Apache-2.0 | 音频播放 |
| `cpal` | 0.15 | MIT / Apache-2.0 | 音频后端抽象 |
| `lofty` | 0.24 | MIT / Apache-2.0 | 音频标签读写 |
| `image` | 0.25 | MIT / Apache-2.0 | 图像解码（jpeg/png/bmp/webp） |
| `rustfft` | 6 | MIT / Apache-2.0 | FFT |
| `signalsmith-stretch` | 0.1.3 | MIT | 音频伸缩 |
| `anyhow` / `thiserror` / `parking_lot` / `tracing*` / `time` / `walkdir` / `tokio` / `libc` | 各 | MIT / Apache-2.0 | 基础设施 |

## FFmpeg 静态链接特别声明（LGPL）

本引擎通过 `ffmpeg_audio` crate 将 **FFmpeg** 以**静态库形式编译并链接**进原生模块。
经构建配置确认（`config.h` 中 `CONFIG_GPL=0`、`CONFIG_NONFREE=0`），
所用 FFmpeg 为**纯 LGPL 构建**，未启用任何 GPL/nonfree 外部编解码库。

依据 LGPL-2.1 第 6 条（静态链接情形），该原生模块被视为对 FFmpeg 库的修改作品，
使用者享有以下权利：

1. 获得 FFmpeg 对应源代码的自由；
2. 使用修改后的 FFmpeg 重新链接、替换该模块中 FFmpeg 部分的自由。

### FFmpeg 源代码获取

- FFmpeg 官方：https://ffmpeg.org/
- 本软件所用 FFmpeg 封装与构建配置（vendor 产物按平台生成）：
  https://github.com/SPlayer-Dev/ffmpeg-audio

### 可重链说明

为满足 LGPL 第 6(b) 条「提供可与之重新链接的目标文件」要求，本软件在公开发布仓库中
提供 `ffmpeg_audio` 的完整 Rust 封装源码、原生模块源码与构建脚本，
使用者可自行取得 FFmpeg 对应版本（LGPL）源码后重新执行构建以完成替换/重链。

## 自写播放器（C 引擎内置，§10.8）

播放器输出设备使用 **miniaudio**（单头文件，v0.11.25）：

| 组件 | 版本 | 许可证 | 说明 |
|---|---|---|---|
| `miniaudio` | v0.11.25 | MIT-0 / 公有领域（Public Domain）双许可 | 跨平台音频输出（ALSA/PulseAudio/PipeWire/WASAPI/CoreAudio），`include/miniaudio.h` 单头文件 |

- MIT-0 许可证文本见 `include/miniaudio.h` 文件头。
- 不引入 GPL 依赖：播放链路（解码由 FFmpeg、输出由 miniaudio）整体为
  FFmpeg(LGPL) + miniaudio(MIT-0) + 自研代码，与 AGPL-3.0 兼容。

## 许可兼容性结论

FFmpeg（LGPL）与本软件全部 MIT/Apache 依赖均兼容 AGPL-3.0；
本音频引擎整体作为 AGPL-3.0 受保护作品的一部分分发，合规。

---
AGPL-3.0 完整文本见仓库根 `LICENSE`；第三方声明总览见根 `THIRD-PARTY-NOTICES.md`。
