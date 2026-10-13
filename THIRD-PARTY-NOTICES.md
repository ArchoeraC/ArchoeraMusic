# 第三方运行库许可声明（随发布产物分发）

本文件随 ArchoeraMusic 发布产物（`licenses/` 目录）一并分发，列出**随包内嵌**的
第三方运行库、其许可、源码获取方式与 LGPL 赋予的替换权。各原生模块自身的第三方
登记见 `app/core/*/THIRD-PARTY-LICENSES.md`。

本软件整体以 **AGPL-3.0** 授权（见根 `LICENSE`）。第三方组件按各自许可继续适用，
仅并入与 AGPL-3.0 兼容的组件（LGPL-2.1+ / LGPL-3.0+ / MIT / BSD / Apache-2.0 /
MPL-1.1 / 公有领域）。

## 随包内嵌的运行库

### FFmpeg 9.0.1（libavformat / libavcodec / libavutil / libswresample）

- **许可**：Linux/macOS **LGPL-3.0-or-later**、Windows **LGPL-2.1-or-later**（均为**纯 LGPL
  · 仅音频构建**：`--disable-gpl --disable-nonfree --disable-autodetect --disable-everything`
  后仅启用音频解码/解复用/解析与 Opus 编码，未启用任何 GPL/nonfree 组件，也未编译任何
  视频/图像解码器）。Linux/macOS 因自包含 TLS 使用 mbedTLS（Apache-2.0，FFmpeg 列为 version3
  依赖）而带 `--enable-version3`，故升为 LGPL-3.0-or-later；Windows 用系统原生 Schannel，不带
  `version3`，维持 LGPL-2.1-or-later。两者均无 GPL，AGPL-3.0 聚合分发兼容。
- **链接方式**：动态链接（未静态合并）。
- **源码**：https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz
  （构建脚本与确切配置见 `app/core/build-ffmpeg-minimal.sh`）。
- **许可文本**：同目录 `COPYING.LGPLv3`、`COPYING.LGPLv2.1`、`LICENSE.md`。
- **替换权**：依 LGPL，你可获得对应源码，并以修改后的 FFmpeg 动态库替换本程序
  运行时所加载的内嵌库（Linux `native/libav*`、macOS `Contents/native/libav*`、
  Windows exe 根目录的 `av*.dll`）。

### libopus（libopus.so.0 / libopus.dylib / opus.dll）

- **许可**：BSD-3-Clause（Xiph.Org / Jean-Marc Valin 等）。
- **用途**：Opus 编码（FFmpeg 的 `libopus` 编码器，OGG/Opus 转码输出）。
- **链接方式**：动态链接（未静态合并），随包内嵌（Linux `native/libopus.so.0`、
  macOS `Contents/native/libopus*.dylib`、Windows exe 根目录 `opus.dll`）。
- **源码**：https://opus-codec.org/downloads/ ｜ https://github.com/xiph/opus
- **许可文本**：同目录 `opus-COPYING`（或见 `app/core/audio-engine/THIRD-PARTY-LICENSES.md`）。

### TagLib（libtag）

- **许可**：LGPL-2.1-or-later 与 MPL-1.1 双许可。
- **链接方式**：动态链接（未静态合并）。
- **源码**：https://github.com/taglib/taglib
- **许可文本**：同目录 `TagLib-LICENSE.txt`（部分发行版未随包提供，则依
  `COPYING.LGPLv2.1`，两者为同一 LGPL-2.1 许可文本）。
- **替换权**：依 LGPL-2.1，你可获得对应源码，并以修改后的 TagLib 动态库替换本程序
  运行时所加载的 `libtag` / `libtag.dylib` / `tag.dll`。

## 编译期内嵌的托管 / 语言运行时依赖（各原生模块）

以下组件经各自语言工具链**随附源码编译进**本程序分发的原生库（如 `scanner-ffi`、`indexer-ffi`），
许可均为宽松或 weak-copyleft，与 AGPL-3.0 聚合分发兼容；逐项说明与源码获取方式见对应模块的
`THIRD-PARTY-LICENSES.md`。各模块的**逐项清单（含传递依赖）**随包分发为
`licenses/<模块>-THIRD-PARTY-LICENSES.md`（如 `audio-engine-THIRD-PARTY-LICENSES.md`、
`downloader-THIRD-PARTY-LICENSES.md`、`scraper-THIRD-PARTY-LICENSES.md`、
`subsonic-THIRD-PARTY-LICENSES.md` 等）。

| 模块 | 组件 | 许可 | 说明 |
|---|---|---|---|
| scanner（C#） | `TagLibSharp` 2.3.0 | **LGPL-2.1** | 音频元数据读写；.NET 程序集引用，替换/重链说明见模块文档 |
| scanner（C#） | `Microsoft.Data.Sqlite` 10.0.12 | MIT | SQLite 的 ADO.NET 提供程序 |
| scanner（C#） | `SQLitePCLRaw.lib.e_sqlite3` 3.53.3 | **Apache-2.0** | 原生 SQLite（SQLite 本体与 FTS5 为**公有领域**），随 FFI 分发 |
| indexer（C#） | `ToolGood.Words` 3.1.0.3 | **Apache-2.0** | 汉字转拼音（词级多音字）、繁简 / 全角互换 |
| indexer（C#） | `Microsoft.Data.Sqlite` 10.0.12 | MIT | SQLite 的 ADO.NET 提供程序 |
| indexer（C#） | `SQLitePCLRaw.lib.e_sqlite3` 3.53.3 | **Apache-2.0** | 原生 SQLite（含 FTS5，公有领域），随 FFI 分发 |

> 本地曲库搜索索引器另内嵌由 Unicode 数据离线生成的查询表（`data/nfkc.tsv`、
> `data/def_en2hanzi.tsv`、`data/def_hanzi2en.tsv`，派生自 **Unihan `kDefinition`** 等），
> 受 [Unicode License](https://www.unicode.org/license.txt) 约束——详见
> `app/core/indexer/THIRD-PARTY-LICENSES.md`。

## 在线服务 / 外部 API（非内嵌代码）

本程序可选用第三方在线服务；这些服务**不随包分发**，仅经其公开 HTTP API 访问，**不并入、不链接其源代码**。

### NekoMusic / Neko 歌姬计划（实验性音源，默认关闭）

- **性质**：第三方在线音乐平台。服务端以 GPL-3.0 授权；官方 PC 客户端以 AGPL-3.0 授权，
  并依 AGPLv3 §7 声明**附加条款**（强制开源、署名与源码公示、禁止冒名顶替）。
- **接入方式**：仅调用其公开 REST API（登录 / 搜索 / 收藏 / 歌单 / 音频直链 / 歌词），
  **未复制、未链接其源代码**；音频下载扩展名由本项目按**文件头魔数**自行实现（通用容器嗅探）。
- **附加条款合规**：本程序在「设置 → 关于」页显著位置署名
  「本程序由 Neko 歌姬计划 API 提供技术支持」，并给出本项目源码仓库与
  [Neko 歌姬计划 API 文档](https://github.com/FantasyNetworkCN/NekoMusicDocs) 链接。
- **默认状态**：**关闭**；仅用户显式开启该实验性音源后才会请求其服务。

## 字体 / 图标许可

随包内嵌的字体（**MiSans**、**Manrope**）与自建图标字体 **EtaIcons**（字形来自
MingCute / Tabler / Lucide）的**官方许可正文**一并随 `licenses/` 目录分发
（同源文件见 `app/assets/licenses/`），并在「设置 → 关于 → 字体署名」中完整展示。
字体/图标来源与许可逐项见 `docs/acknowledgements.md`。

## 应用内查看

随包 `licenses/` 目录分发以下**完整许可正文**（同源文件见 `app/assets/licenses/`）：
**GNU AGPL-3.0**（本程序自身许可，仓库根 `LICENSE` 的随包副本）、
**Apache-2.0、MIT、BSD-3-Clause、ISC、MPL-2.0、LGPL-2.1、LGPL-3.0、MIT-0、CC0-1.0、
Unlicense、WTFPL、Unicode License**（另含字体 / 图标官方正文 MiSans / Manrope OFL-1.1 /
EtaIcons 上游字形集许可）。各组件完整许可正文并在应用内「设置 → 关于 → 第三方开源许可」
中按许可正文分组查看（随包原生依赖 + Dart/Flutter pub 依赖）；未被任何组件直接引用的
正文亦在该弹窗末尾「其他随包许可正文」兜底列出。各原生模块的**逐项清单（含传递依赖）**
随包分发为 `licenses/<模块>-THIRD-PARTY-LICENSES.md`。

## 合规说明（非法律意见）

- FFmpeg / TagLib 均以**动态库**形式使用，未静态合并；本仓库随源码提供构建配置，
  并在发布产物 `licenses/` 目录随附许可文本，满足 LGPL「可替换/可重链」要求。
- 本项目遵守「GPL 防火墙」：AGPL-3.0 与 GPL-2.0-only 不可合并分发；故不使用任何
  GPL/nonfree 构建的 FFmpeg（例如 Homebrew 默认 `--enable-gpl` 的 ffmpeg）。
- 以 GPL/AGPL 授权的第三方**在线服务**（如 Neko 歌姬计划）仅经公开 HTTP API 互操作，
  未将其代码并入本程序分发（见上文「在线服务 / 外部 API」）。
- 本文档为项目维护者的合理努力整理，不构成法律意见；正式依据以上游官方许可文本为准。
