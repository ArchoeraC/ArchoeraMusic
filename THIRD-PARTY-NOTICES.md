# 第三方运行库许可声明（随发布产物分发）

本文件随 ArchoeraMusic 发布产物（`licenses/` 目录）一并分发，列出**随包内嵌**的
第三方运行库、其许可、源码获取方式与 LGPL 赋予的替换权。各原生模块自身的第三方
登记见 `app/core/*/THIRD-PARTY-LICENSES.md`。

本软件整体以 **AGPL-3.0** 授权（见根 `LICENSE`）。第三方组件按各自许可继续适用，
仅并入与 AGPL-3.0 兼容的组件（LGPL-2.1+ / MIT / BSD / Apache-2.0 / MPL-1.1 / 公有领域）。

## 随包内嵌的运行库

### FFmpeg 7.1.1（libavformat / libavcodec / libavutil / libswresample）

- **许可**：LGPL-2.1-or-later（**纯 LGPL 构建**：`--disable-gpl --disable-nonfree
  --disable-autodetect`，未启用任何 GPL/nonfree 组件）。
- **链接方式**：动态链接（未静态合并）。
- **源码**：https://ffmpeg.org/releases/ffmpeg-7.1.1.tar.xz
  （构建脚本与确切配置见 `app/core/build-ffmpeg-minimal.sh`）。
- **许可文本**：同目录 `COPYING.LGPLv2.1`、`LICENSE.md`。
- **替换权**：依 LGPL-2.1，你可获得对应源码，并以修改后的 FFmpeg 动态库替换本程序
  运行时所加载的内嵌库（Linux `native/libav*`、macOS `Contents/native/libav*`、
  Windows exe 根目录的 `av*.dll`）。

### TagLib（libtag）

- **许可**：LGPL-2.1-or-later 与 MPL-1.1 双许可。
- **链接方式**：动态链接（未静态合并）。
- **源码**：https://github.com/taglib/taglib
- **许可文本**：同目录 `TagLib-LICENSE.txt`（部分发行版未随包提供，则依
  `COPYING.LGPLv2.1`，两者为同一 LGPL-2.1 许可文本）。
- **替换权**：依 LGPL-2.1，你可获得对应源码，并以修改后的 TagLib 动态库替换本程序
  运行时所加载的 `libtag` / `libtag.dylib` / `tag.dll`。

## 合规说明（非法律意见）

- FFmpeg / TagLib 均以**动态库**形式使用，未静态合并；本仓库随源码提供构建配置，
  并在发布产物 `licenses/` 目录随附许可文本，满足 LGPL「可替换/可重链」要求。
- 本项目遵守「GPL 防火墙」：AGPL-3.0 与 GPL-2.0-only 不可合并分发；故不使用任何
  GPL/nonfree 构建的 FFmpeg（例如 Homebrew 默认 `--enable-gpl` 的 ffmpeg）。
- 本文档为项目维护者的合理努力整理，不构成法律意见；正式依据以上游官方许可文本为准。
