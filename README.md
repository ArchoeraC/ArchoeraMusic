<p align="center">
  <img src="logo.png" width="128" height="128" alt="ArchoeraMusic">
</p>

# ArchoeraMusic

> 开源、多端、面向本地与在线音乐的混合架构播放器

<p align="center">
  <img src="screenshot.png" width="720" alt="ArchoeraMusic 主界面">
</p>

---

## 目录

1. [项目简介](#项目简介)
2. [技术架构](#技术架构)
3. [项目结构](#项目结构)
4. [构建与运行](#构建与运行)
5. [文档](#文档)
6. [许可证（Licensing）](#许可证licensing)
7. [第三方声明](#第三方声明)
8. [特别鸣谢（Acknowledgements）](#特别鸣谢acknowledgements)
9. [联系与贡献](#联系与贡献)

---

## 项目简介

ArchoeraMusic 是一个开源的**多平台音乐播放器**，定位「桌面为主（Linux / Windows / macOS）」，UI 层采用 Flutter 开发。

- 连接**网易云音乐 / 酷狗音乐 / QQ 音乐**等在线服务（纯 Dart 直连，无需代理侧车）
- 支持本地音乐库扫描与元数据刮削、多平台下载
- 内置统一 C 音频引擎：EQ / 响度归一化 / 限幅器 / FFT 频谱 / 变速变调 / Opus 转码管线
- 桌面端原生模块 **FFI 直连**（`archoera_mediaengine` 共享库），零子进程、零 TCP 端口暴露
- 可选内置 **Subsonic 兼容服务端**（Go），并支持 Subsonic / Jellyfin 流媒体服务器聚合

---

## 技术架构

```
┌───────────────────────────────────────────────────────────────┐
│ Flutter App（Dart）                                            │
│  ├─ UI：Riverpod 状态 · go_router 路由 · 自绘歌词/频谱           │
│  ├─ 业务层：PlaybackController · 平台 API（纯 Dart）· 事件总线  │
│  ├─ 桥接层：engine_bindings（FFI 直连 mediaengine）· 平台壳      │
│  └─ 平台壳：linux / windows / macos                            │
└───────────────────────────┬───────────────────────────────────┘
                            │ FFI 直连
┌───────────────────────────┴───────────────────────────────────┐
│ 多语言原生工具链                                               │
│  ├─ C   `archoera-audio-engine`  解码→DSP→Opus 编码（主引擎）   │
│  ├─ C#  `archoera-scanner`       音乐库扫描 TagLibSharp         │
│  ├─ C++ `archoera-scraper`       元数据刮削 + TagLib 写入       │
│  ├─ Rust tempo-rs               变速变调（静态链接进 C 引擎）   │
│  └─ Go  `archoera-subsonic`     Subsonic 服务端（可选启用）     │
└───────────────────────────────────────────────────────────────┘
```

**关键架构决策**：

- **平台协议层纯 Dart 化**：网易云/酷狗/QQ 音乐签名算法与请求逻辑全部 Dart 移植，无 Node 侧车
- **桌面端原生 FFI 直连**：音频引擎（`archoera_mediaengine` 共享库）进程内转码 + libmpv 渲染，零子进程、零端口暴露
- **统一音频管线**：在线/本地共用 C 引擎 Opus 转码管线，DSP 在引擎内完成
- **Subsonic 代码复用**：Go Subsonic 在桌面端与独立服务端**完全共享一份代码**，通过 build tag 区分（详见 [架构文档](docs/architecture.md)）

---

## 项目结构

```
ArchoeraMusic/
├── LICENSE                     # 许可证正文（AGPL-3.0，见下文升级策略）
├── README.md                   # 本文件
├── .gitignore
├── app/                        # Flutter 应用
│   ├── pubspec.yaml            # 应用清单（版本 / 依赖 / 国际化）
│   ├── l10n.yaml               # 国际化配置
│   ├── analysis_options.yaml
│   ├── assets/                 # 字体（NotoSC / MiSans / HarmonyOS SC）、图标
│   ├── lib/
│   │   ├── main.dart
│   │   ├── apis/               # 纯 Dart 平台 API：netease / kugou / qqmusic / lyric
│   │   ├── app/                # 应用壳：bootstrap / router / shell / theme_provider
│   │   ├── pages/              # 页面：home / library / liked / streaming / download 等
│   │   ├── services/           # 业务层：playback / scanner / scraper / downloader / subsonic 等
│   │   ├── stores/             # Riverpod 状态：app_prefs / playback_session / event_bus
│   │   ├── settings/           # 设置弹窗与媒体源管理
│   │   ├── theme/              # 主题与封面取色
│   │   ├── widgets/            # 组件：common / layout / player / list / dialogs
│   │   └── l10n/               # 国际化（ARB 源 + 生成）
│   ├── linux/ windows/ macos/  # 平台壳
│   └── core/                   # 多语言原生模块（源码，Windows 由 build_windows.bat 一站式构建）
│       ├── audio-engine/       # C + Rust tempo-rs（FFmpeg / Opus / EQ / FFT / Tempo）
│       ├── scanner/            # C# NativeAOT（TagLibSharp + SqliteDirectWriter）
│       ├── scraper/            # C++（多源刮削 + TagLib 写入）
│       ├── downloader/         # Rust 下载引擎（Kugou / Netease 自研签名 + FFI）
│       └── subsonic/           # Go Subsonic 服务（桌面 FFI / 独立服务共享，含 Rust 转码器）
└── docs/
    ├── architecture.md         # 架构设计（进程模型 / 音频管线 / FFI 桥接）
    └── download-module.md      # 下载模块设计规范
```

---

## 构建与运行

> CI：仓库 `.github/workflows/` 提供三端（Linux / Windows / macOS）完整构建
> workflows，手动触发或推送 `v*` 标签时构建全部原生模块 + Flutter 应用并上传产物。

### 前置

- Flutter SDK `^3.12.2`（`cat app/pubspec.yaml | grep sdk`）
- CMake ≥ 3.16 / C 工具链（构建 audio-engine / scraper；`FindSQLite3` 自 3.14 起才提供 `SQLite3::SQLite3` target，低版本将回退到变量链接）
- .NET SDK（构建 scanner）
- Rust 工具链（构建 tempo-rs / transcoder）
- Go 工具链（构建 subsonic）

### 快速开始

```bash
# 1. 拿源码
git clone https://github.com/BetaStudio2/ArchoeraMusic.git
cd ArchoeraMusic

# 2. 构建原生模块
#   Linux / macOS：逐模块构建（入口与 CI workflow 对齐，见 .github/workflows/build-*.yml）
#     audio-engine: cmake -S app/core/audio-engine -B app/core/audio-engine/build -DCMAKE_BUILD_TYPE=Release && cmake --build ...
#     scanner:      bash app/core/scanner/build.sh <linux-x64|osx-arm64>
#     scraper:      cmake -S app/core/scraper -B app/core/scraper/build -DCMAKE_BUILD_TYPE=Release && cmake --build ...
#     downloader:   cargo build --release --manifest-path app/core/downloader/Cargo.toml
#     subsonic:     bash app/core/subsonic/build.sh
#   Windows：app/core/build_windows.bat 一站式构建（vcpkg + MSVC，见脚本头注释）

# 3. 启动 Flutter
cd app
flutter pub get
flutter run -d linux      # 或 windows / macos
```

> 提示：Windows / macOS 桌面端的原生模块（audio-engine / scanner / scraper / downloader / subsonic）经 **FFI** 以共享库形式（`archoera_mediaengine.dll` / `libarchoera_subsonic.dylib` 等）打进应用 bundle，无需子进程。

---

## 文档

- [架构设计](docs/architecture.md) —— 进程模型 / 音频管线 / FFI 桥接
- [下载模块设计规范](docs/download-module.md) —— 下载引擎架构 / 事件机制 / 许可约束

---

## 许可证（Licensing）

> **本节必须严格遵守。若对许可证有任何疑问，请先咨询再修改或分发。**

### 1. 当前许可证

本项目整体以 **GNU Affero General Public License, version 3（AGPL-3.0）** 发布（许可证正文见仓库根 [LICENSE](LICENSE)），并采用 **AGPL-3.0-or-later** 弹性授权策略（含 "or any later version" 条款，升级触发与流程见下文「未来许可证升级策略」）。

- **版权持有者**：BetaStudio2
- **起始许可版本**：AGPL-3.0（`AGPL-3.0-or-later`，含后续版本弹性条款）
- **代码归属**：本项目（含所引用的服务端代码）均为本仓库作者进行编写

#### 各原生模块的声明

每个原生子模块内均带有 `THIRD-PARTY-LICENSES.md`，列清单个直接/间接依赖：

| 模块 | 位置 | 备注 |
|---|---|---|
| C 音频引擎 | `app/core/audio-engine/THIRD-PARTY-LICENSES.md` | miniaudio / FFmpeg 等 |
| 扫描器（C#） | `app/core/scanner/THIRD-PARTY-LICENSES.md` | TagLibSharp / SQLitePCLRaw |
| 刮削器（C++） | `app/core/scraper/THIRD-PARTY-LICENSES.md` | TagLib / nlohmann-json |
| 下载引擎（Rust） | `app/core/downloader/THIRD-PARTY-LICENSES.md` | reqwest / lofty / RustCrypto |
| Subsonic（Go + Rust） | `app/core/subsonic/THIRD-PARTY-LICENSES.md` | 转码器 / Go 依赖 |

所有第三方依赖均为 **Permissive License（MIT / Apache-2.0 / WTFPL / BSD-3 / ISC / OFL）**，与 AGPL-3.0 完全兼容。

### 2. 未来许可证升级策略（AGPL-v4 及以后）

> 这是一项**长期许可策略声明**，写入仓库以避免后续版本升级时的法律与贡献者授权争议。

#### 2.1 原则

1. **当前（2026-08）为 AGPL-3.0-or-later**：所有现有代码、当前发布的二进制、以及当前历史提交，均以 **AGPL-3.0 及任何后续版本** 为准（已包含 "or any later version" 弹性条款）。
2. **自动升级机制**：由于采用 `AGPL-3.0-or-later`，当 FSF 发布新版 AGPL（如 AGPL-4.0 及以后）时，项目**自动适用**新版本条款，无需逐位贡献者另行授权、也无需版权持有者逐一征询。正式的版本切换按 §2.4 流程执行，以保证透明与可追溯：
   - 切换时以 **BetaStudio2 官方公告 + 仓库根 LICENSE 正文更新 + 提交签名** 为准；
   - 切换后新的 AGPL 版本条款 **立即适用于切换提交及之后所有代码**；
   - 历史提交仍按其提交时的许可证版本保留不变（不追溯）。

#### 2.2 贡献者授权（Contributor License Grant）

任何向本仓库提交代码（PR / patch / 直接推送）的贡献者，被视为已同意以下不可撤销授权：

> **本人（贡献者）特此授权版权持有者 BetaStudio2，将本人贡献的代码，连同项目整体，一并以"AGPL-3.0 及任何更高版本的 GNU Affero General Public License"进行再许可、分发与修改。该授权在全球范围内、永久、不可撤销、免版税。**

这意味着：

- 由于项目已采用 `AGPL-3.0-or-later`，未来 FSF 发布新版 AGPL（如 **AGPL-4.0**）后，**所有历史贡献将自动被纳入新版本授权范围**，贡献者不得另行主张或拒绝；
- 贡献者在本项目的个人署名权将被保留（git author / changelog 等），但不影响上述再许可授权。

#### 2.3 升级到 AGPL-v4 的触发条件（非承诺，仅为指引）

升级不是必然发生的。预计在以下任一条件成熟时考虑启动升级流程：

- GNU 官方正式发布 **AGPL-4.0** 并获得社区广泛采用；
- AGPL-4.0 对 AI / LLM 训练场景、SaaS / 云端托管场景、或 DRM / 签名校验绕开等问题有更明确的条款补强；
- 出现需要新条款来保护用户自由或项目生态的新情况（如云厂商闭源改造但不释放源码等）。

#### 2.4 升级流程（预先约定）

1. **公告期（不少于 30 天）**：在 GitHub Issue / 社区渠道发布升级提案，列明原因、新条款差异点，并接受贡献者反馈；
2. **切换 LICENSE 正文**：将仓库根 LICENSE 替换为新版 AGPL 官方正文；
3. **同步更新本节**：README 的许可条款段落明确"自 commit `<hash>` 起，项目切换到 AGPL-x.y"；
4. **版权年度更新**：同步更新版权年份与版权持有者署名（如有必要）；
5. **推送签名提交**：升级提交必须由 BetaStudio2 官方 GPG / SSH 签名密钥签名。

#### 2.5 第三方代码的约束

- 任何**第三方引入代码**（PR 合入的外部代码 / 上游移植）必须携带与 AGPL-3.0（及未来 AGPL-4.0）**兼容**的许可证；
- 严禁引入 GPL-2.0-only（缺少 "or later version"）与 AGPL 不兼容的代码；
- 严禁引入 **SSPL / BSL / SSPL / 商业源可用但禁止商业使用** 等非 FSF 认可的"伪开源"许可证代码；
- 所有引入的第三方代码必须在**对应模块**的 `THIRD-PARTY-LICENSES.md` 中逐项列明。

---

## 第三方声明

详细第三方依赖清单与许可证见各子模块内的 `THIRD-PARTY-LICENSES.md`。

**字体资源许可**（`app/assets/fonts/`）：

| 字体 | 文件 | 许可证 | 要点 |
|---|---|---|---|
| Noto Sans CJK SC | `NotoSC-*.otf` | **SIL OFL 1.1** | 开源字体，可自由使用、修改、分发 |
| MiSans | `MiSans-*.ttf` | 小米《[MiSans 字体知识产权许可协议](https://hyperos.mi.com/font-download/MiSans%E5%AD%97%E4%BD%93%E7%9F%A5%E8%AF%86%E4%BA%A7%E6%9D%83%E8%AE%B8%E5%8F%AF%E5%8D%8F%E8%AE%AE.pdf)》（**非 OFL**） | 免费商用；须在软件中注明使用 MiSans；禁止改编/二次开发字体；禁止单独分发字体文件 |
| HarmonyOS Sans SC | `HarmonyOS_Sans_SC_*.ttf` | 华为《[HarmonyOS Sans 字体许可协议](https://gitcode.com/openharmony/global_system_resources/blob/master/LICENSE_Fonts)》（**非 OFL**） | 免费商用；须突出显示使用 HarmonyOS Sans；禁止修改字体；禁止单独分发字体 |

---

## 特别鸣谢（Acknowledgements）

本项目在架构设计与实现思路上受到了以下开源项目的启发与支持（**仅借鉴思路，未引用其代码**）：

- **[SPlayer-Next](https://github.com/SPlayer-Dev/SPlayer-Next)** —— 混合架构播放器设计、音频引擎管线与在线平台接入的整体思路
- **[KuGouMusicApi](https://github.com/MakcRe/KuGouMusicApi)（MIT）** —— 酷狗平台接口调研与协议逆向思路参考
- **[NeteaseCloudMusicApi](https://github.com/Binaryify/NeteaseCloudMusicApi)（MIT）** —— 网易云平台接口调研与 weapi 加密流程思路参考
- **[ncm-api-rs](https://github.com/SPlayer-Dev/ncm-api-rs)（WTFPL）** —— Rust 化网易云签名实现的备胎参考
- **[MoeKoeMusic](https://github.com/MoeKoeMusic/MoeKoeMusic)** —— 开源高颜值酷狗第三方客户端，桌面端体验与平台接入思路参考
- **[Mineradio](https://github.com/XxHuberrr/Mineradio)** —— Windows 桌面沉浸式音乐播放器，歌词舞台与视觉呈现思路参考

> 特别说明：以上项目与 ArchoeraMusic **无代码归属关系**，本项目（含所引用的服务端代码）均由本仓库作者自行编写，不在 SPlayer / SPlayer-Next 主仓库内；此处仅表达对相关项目思路的认可与致谢。

---

## 联系与贡献

- 仓库：<https://github.com/BetaStudio2/ArchoeraMusic>

贡献前请阅读 [docs/architecture.md](docs/architecture.md) 中的实施路线与技术戒律。PR 合入前需要通过签名或显式确认接受上文「贡献者授权」条款。
