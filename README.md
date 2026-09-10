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

> **使用声明（太长不看版）**：本项目自研代码以 **AGPL-3.0-or-later** 开源。
> **AGPL 认可开源商业化**：在遵守其义务（分发或提供网络服务时以 AGPL 开放源码、保留声明并标注修改）的前提下，
> 自由使用、学习、修改与再分发（包括商业用途）均被许可；**AGPL 不认可闭源商业化**——不开放源码的
> 闭源集成、换壳/套壳再分发、不开放源码的商业托管/网络服务等不在授权范围内，本项目也不提供闭源商业授权。
> 本声明仅为开发者对授权边界的说明，法律层面以根目录 `LICENSE`（AGPL-3.0-or-later）为准。

- 连接**网易云音乐 / 酷狗音乐 / QQ 音乐**等在线服务
- 支持本地音乐库扫描与元数据刮削、多平台下载
- 内置统一 C 音频引擎：EQ / 响度归一化 / 限幅器 / FFT 频谱 / 变速变调 / Opus 转码管线
- 桌面端原生模块 **FFI 直连**（`archoera_mediaengine` 共享库）
- 可选启动 **Subsonic 兼容服务端**（Go），并支持 Subsonic / Jellyfin 流媒体服务器聚合

### 本地曲库：扫描与刮削

音乐库扫描（C# `archoera-scanner`）与元数据刮削 / 目录整理（C++ `archoera-scraper`）均以 **FFI 直连、进程内执行**，不占用本地端口：

**扫描（音乐库）**

- **增量扫描**：进入音乐库页自动刷新（5 分钟去重）或点刷新按钮手动触发；
  **全量扫描重建**：音乐库页 `⋯` 菜单 →「全量扫描」，确认后清空曲库 DB 并从扫描目录重建（不删除源文件）。
- **运行设置**：扫描并行度（0=自动，按 CPU/内存自适应）、数据库批量写入上限。
- **安全上限**：单文件大小、单轮最大文件数、连续解析错误数（可自定义；默认 500MB / 50000 / 50）。
- **自定义音频扩展名**：在内置白名单（`mp3 flac ogg opus oga m4a aac wav ape wv dsf dsd dff mp4 aiff aif wma mka mpc mpp mp+ mp2 aifc m4b webm`）之上追加自定义扩展名。
- **坏文件隔离区**：连续解析失败 ≥3 次的文件自动移入 `database/quarantine/`，可在扫描设置中浏览、单删 / 清空或打开目录。
- 扫描目录管理在音乐库页 `⋯` →「扫描目录」（多目录、路径去重）。

**刮削（元数据补齐）**

- **多源并发刮削**：MusicBrainz（权威 + MBID/ISRC）、Deezer、iTunes、网易云、QQ 音乐、酷狗、酷我、咪咕 8 个在线源，外加 **AcoustID 音频指纹**回退；命中相似度评分、多源字段择优合并，并自动补封面（Cover Art Archive → 各源回退）与歌词（LRCLIB → 中文源）。
- **写入选项**：元数据 / 封面 / 歌词嵌入开关；**跳过已刮削**（已有 MusicBrainz ID 或 ISRC 的文件不再重复联网）。
- **高级参数**：并发查询线程数（0=自动）、批大小、失败重试上限（超出后不再重试）。
- **仅目录整理（不联网）**：按模板把目录内文件移动到目标目录树——可用变量 `artist / albumArtist / album / genre / year / disc / track / title / ext`，以 `/` 分隔目录层级，**始终保留原文件名**；内置 歌手/专辑、仅歌手、风格/歌手/专辑、年份/歌手/专辑 四套预设模板。
- 刮削成功后把标签写入音频文件（ID3v2 / Xiph / MP4 / RIFF 等），封面写入标签与本地封面缓存；结果经「下次扫描」读取入库。

**UI 入口**：设置 →「刮削」（目录 / 数据源 / 写入选项 / 高级参数 / 仅目录整理）；设置 →「扫描」（并行度、上限、扩展名、隔离区）；音乐库页 `⋯` 菜单（扫描目录 / 全量扫描 / 媒体统计）。

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

- **平台协议层纯 Dart 化**：网易云/酷狗/QQ 音乐签名算法与请求逻辑全 Dart 化
- **桌面端原生 FFI 直连**：音频引擎（`archoera_mediaengine` 共享库）进程内转码 + miniaudio
- **统一音频管线**：在线/本地共用 C 引擎转码管线，DSP 在引擎内完成
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

> CI：仓库 `.github/workflows/` 提供三端（Linux / Windows / macOS）完整打包
> workflows，手动触发或推送 `v*` 标签时构建全部原生模块 + Flutter 应用并上传产物。

### 前置

- Flutter SDK `^3.12.2`（`cat app/pubspec.yaml | grep sdk`）
- CMake ≥ 3.16 / C 工具链（构建 audio-engine / scraper；`FindSQLite3` 自 3.14 起才提供 `SQLite3::SQLite3` target，低版本将回退到变量链接）
- **Zig 0.16.x**（自研解码内核 EraAudio，`app/core/audio-engine/kernel`；编译顺序：先 `zig build -Doptimize=ReleaseFast`
  再 cmake 构建 audio-engine，缺失时引擎回退 FFmpeg/Stable——详见 `docs/engine-integration-bench.md`）
- .NET SDK（构建 scanner）
- Rust 工具链（构建 tempo-rs / transcoder）
- Go 工具链（构建 subsonic）

### 快速开始

> 面向用户的完整自编译手册（含「太长不看版」速通命令、三端环境、缓存外置与常见问题）：
> **[docs/user-build-from-source.md](docs/user-build-from-source.md)**。下方为快速副本。

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

> 提示：Windows / macOS 桌面端的原生模块经 **FFI** 以共享库形式（`archoera_mediaengine.dll` / `libarchoera_subsonic.dylib` 等）打进应用，无需子进程。

---

## 自研解码内核基准（EraAudio，实验性）

> 2026-09-05 行业对比（FFmpeg n9.0.1 / libFLAC / LAME / speexdec / libopus / libvorbis）。
> 定位：**实验性参考，非发布承诺**。自研 Zig 内核（`--engine-mode 1`）当前为「优先尝试、
> 失败回退 FFmpeg」的渐进接管路线，基准用于量化差距、排定优化项。
> 全量方法/原始数据/复现见 [docs/benchmark-industry-2026-09-05.md](docs/benchmark-industry-2026-09-05.md)，
> 引擎集成与旧口径基准见 [docs/engine-integration-bench.md](docs/engine-integration-bench.md)。

**总体评分（100 = speed40 + memory30 + correctness20 + coverage10）**：
EraAudio **95.6/100（A+；跨轮 95.0–95.6）** vs 引擎内 Stable/FFmpeg 97.6（A+）→
**相对 FFmpeg ≈97.9%**（Δ≈−2.0，区间 97.0%–97.9%）；`flac -d` / `lame --decode`
（各自格式、作地面真值）100；`speexdec` 80（极性分歧，见 doc）。同机：Intel i9-13980HX ·
Linux · 200s 高熵噪声语料 · 解码→PCM 不重编码；lossless 类 native 输出与 FFmpeg **逐位一致**，
lossy 类 `|corr|≥0.999`、`±≤1 LSB`（ac3/eac3≈0.96、speex 极性分歧另注）。贴近阈值行有
±4 分跨轮抖动（ac3/flac/m4a），判档请看区间与分差方向。

| 格式 | EraAudio | Stable(FFmpeg) | 格式 | EraAudio | Stable(FFmpeg) |
|---|---|---|---|---|---|
| flac(直解) | 97.9 A+ | 100 A+ | mp2 | 100 A+ | 96 A+ |
| wav / wv / mka | 100 A+ | 100 A+ | opus | 100 A+ | 100 A+ |
| tta | 82 B | 100 A+ | vorbis | 100 A+ | 100 A+ |
| mp3 | 100 A+ | 96 A+ | aac(m4a) | 100 A+ | 96 A+ |
| dts | 82 B | 96 A+ | aac(adts) | 100 A+ | 96 A+ |
| speex | 88 B | 88 B | ac3 | 92 A | 100 A+ |
| | | | eac3 | 92 A | 96 A+ |

**已知短板（评分依据，详见 doc §6）**：① 直解 `.flac` native ≈46–50× 实时（比 FFmpeg 慢 ~20×，
自研 flac 帧解码器待优化；经 mka 轨 ≈260–280× 正常）；② tta/dts 峰值 RSS 55/85MB（平台 ≈29MB，
疑似整缓冲，待多尺寸验证）；③ ac3/eac3 PCM 与参考 corr≈0.96（长度对齐，内容级舍入差待核对）；
④ speex 与独立 `speexdec` 极性分歧（libspeex 族同号，编码侧成因，按 |corr| 计分）。

重跑命令（产物落 `app/core/audio-engine/tests/bench/`）：

```bash
cd app/core/audio-engine
zig build -Doptimize=ReleaseFast && cmake --build build
python3 tests/bench/scorecard.py --corpus /tmp/eng --build-tag <tag>
```

---

## 安全说明（凭据保险库）

> 凭据保险库（`app/core/vault`）对登录会话与流媒体服务器密码做 2-of-2 加密存储。以下说明对**测试后门**与**发布产物边界**作出声明，请勿在生产环境启用任何测试开关。
> **安全漏洞请走私密渠道报告**（[SECURITY.md](SECURITY.md)），禁止公开 Issue / PR / Discussion 讨论漏洞细节。

### 测试明文存储（仅限调试，后期删除）

- `ARCHOERA_VAULT_INSECURE_FILE_STORE=1` 是**测试专用明文存储开关**（份额明文落盘，非真实安全等级），仅存在于**测试构建**：
  - 由 `app/core/vault/build-test.sh`（`#if VAULT_TESTING` 条件编译）产出 `archoera-vault-test`，仅用于本地调试与 CI（headless 无 D-Bus Secret Service 时验证完整加解密链路）；
  - **生产构建** `app/core/vault/build.sh` 产物 `archoera-vault` **不编译该逻辑**——即使设置该环境变量也无法启用明文存储（可对发布产物执行 `strings -el` 验证无 `ARCHOERA_VAULT_INSECURE_FILE_STORE`）；
  - **该测试后门计划在 Linux keyring CI 基建完善后删除**（届时测试改用真实 OS 安全存储）。
- 测试产物 `archoera-vault-test` **绝不进入发布产物**（bundle / 安装包 / release artifact 均不含，打包流程无引用）。

### 二进制替换防护（防「测试/被替换二进制混入安装包」）

- **双重校验（fail-closed）**：
  1. **加载前校验**：`archoera-vault --version` 输出 `ARCHOERA-VAULT-PROD-*` 才允许解析默认路径二进制；
  2. **握手内 marker 校验（主防线）**：每次 serve 会话的握手应答尾部携带构建标记 `BuildInfo.Marker`（PROD/TEST 版本指纹）。主程序解析应答第 5 字段——默认路径解析的 vault 必须为 PROD 标记，**缺失或非 PROD（即携带 `ARCHOERA_VAULT_INSECURE_FILE_STORE` 显式启动指令的测试构建）→ 杀进程 + 删除默认路径副本 + 拒绝解密 + 置版本异常 fatal 态**，UI 顶层 `VaultVersionGate` 全屏拦截，**仅允许用户退出**（不提供销毁/重试等继续操作）；
- 即使攻击者通过木马等方式把预编译的测试二进制（含明文存储后门）下载并替换进应用安装包，应用**不会加载它**；即便绕过加载前 `--version` 校验，握手阶段 marker 校验仍会拒绝并删除副本——凭据无法被该后门读取；
- `ARCHOERA_VAULT_BIN` 仅作为显式信任边界供测试/CI 使用（设置进程环境本身即需系统权限，生产路径绝不设置）：env 显式指定的二进制跳过 PROD 校验（信任边界），但 marker 存在性仍校验（防旧版协议误判）。

### 信任根边界（威胁模型声明）

- **应用层防线覆盖范围**：仅替换 vault 二进制（→ 双重校验 fail-closed 删副本）、爆破主密钥（→ 2-of-2 + Argon2id + 退避锁定）——均已纵深防护；
- **边界**：信任根在主程序进程。攻击者**同时替换主程序（Dart 可执行 / FFI 库）** 或**在其内嵌主动联网上传程序段**时，vault 视主进程为合法握手对象、无法区分被篡改的主程序——此威胁（进程注入 / 信任根攻破）**超出应用层能力**，由 OS 信任链承担：Windows Authenticode 签名 / macOS 公证 / 安装包完整性校验（已列入 credential-vault-plan 待办）；
- 本方案无法承诺具有拦截「同用户权限下完全控制进程 / 按源码重实现的攻击者」的能力（Kerckhoffs 原则，见 [credential-vault-plan §1.2](docs/credential-vault-plan.md)）。

### 份额覆盖风险与恢复（OS 安全存储全局共享）

- **现象**：解锁报 `The computed authentication tag did not match the input authentication tag`，应用降级为内存态（日志「凭据保险库不可用，登录态将不持久化」），功能可用但重启需重新登录。
- **根因**：OS 模式（v1）下授权侧份额 S 存于 OS 安全存储（Linux Secret Service / macOS Keychain / Windows DPAPI），**存储键全局共享、无 per-app 隔离**（Linux 为 schema `archoera.vault` / account `master-share`）。同一设备上**任何一份应用副本**（安装包 / 开发 bundle / CI 产物）在 vault 未初始化时执行 `init` 都会**覆盖**该份额——若 vault 文件与份额不同代（例如更新前初始化、之后另一副本再次 `init` 覆盖份额），即出现上述解锁失败；**覆盖不可逆，旧份额无法找回，旧登录态不可恢复**。
- **恢复**：删除应用数据目录下的 `credentials.vault`（及同目录 `vault.lockout` / `vault.auth` 残留），应用下次启动自动初始化全新 vault——**旧登录态丢失，需重新登录各平台账号**；或直接执行 `archoera-vault destroy <数据目录>`（一并删除份额与锁定状态）后重启应用。
- **数据目录**：Linux `~/.local/share/ArchoeraMusic`；macOS/Windows 见应用数据目录（路径解析见 `resolveDataDir()`）。
- **避免**：勿在同一设备上同时运行多份不同数据目录的应用副本并各自初始化；升级/替换安装包前如需保留登录态，**不要删除 vault 文件**，并避免在新副本上触发重新初始化。

---

## 文档

- [架构设计](docs/architecture.md) —— 进程模型 / 音频管线 / FFI 桥接
- [用户自编译手册（太长不看版）](docs/user-build-from-source.md) —— 三端从源码构建 / 调试 / 打包 / 缓存外置 / 常见问题
- [eta 图标体系食用说明](app/lib/eta/README.md) —— EtaIcons/EtaMark 引用写法 / 实心描边命名 / 新增字形 / 重新生成
- [自研解码内核行业基准（EraAudio）](docs/benchmark-industry-2026-09-05.md) —— FFmpeg/libFLAC/LAME/speexdec 横评 + 评分（95.6 A+）
- [引擎集成与基准（EraAudio vs Stable）](docs/engine-integration-bench.md) —— EOF/错误语义、内存流式化、样本数对齐
- [音频 Zig 解码内核路线图](docs/audio-kernel-zig.md) —— 内核架构 / 逐格式接管 / 第三方来源登记
- [平台能力外观层](docs/platform-capability-facade.md) —— 防休眠 / 媒体会话与蓝牙耳机控制 / 系统定位的能力接口 + 每平台实现
- [下载模块设计规范](docs/download-module.md) —— 下载引擎架构 / 自研边界 / 依赖许可
- 使用与授权声明见文首；第三方依赖与许可逐项见各模块 `THIRD-PARTY-LICENSES.md`（汇总见「[第三方声明](#第三方声明)」与「[许可证（Licensing）](#许可证licensing)」）

---

## 许可证（Licensing）

> **本节必须严格遵守。若对许可证有任何疑问，请先咨询再修改或分发。**

### 1. 当前许可证

本项目整体以 **GNU Affero General Public License, version 3（AGPL-3.0）** 发布（许可证正文见仓库根 [LICENSE](LICENSE)），并采用 **AGPL-3.0-or-later** 弹性授权策略（含 "or any later version" 条款，升级触发与流程见下文「未来许可证升级策略」）。

- **版权持有者**：BetaStudio2
- **起始许可版本**：AGPL-3.0（`AGPL-3.0-or-later`，含后续版本弹性条款）
- **代码归属**：本项目**自研 / 贡献代码**由本仓库作者与贡献者编写；第三方、移植与参考实现代码按各自来源与许可登记（见各模块 `THIRD-PARTY-LICENSES.md`），本项目不对其主张为自有编写。

#### 各原生模块的声明

每个原生子模块内均带有 `THIRD-PARTY-LICENSES.md`，列清单个直接/间接依赖：

| 模块 | 位置 | 备注 |
|---|---|---|
| C 音频引擎 | `app/core/audio-engine/THIRD-PARTY-LICENSES.md` | miniaudio / FFmpeg 等 |
| 扫描器（C#） | `app/core/scanner/THIRD-PARTY-LICENSES.md` | TagLibSharp / SQLitePCLRaw |
| 刮削器（C++） | `app/core/scraper/THIRD-PARTY-LICENSES.md` | TagLib / nlohmann-json |
| 下载引擎（Rust） | `app/core/downloader/THIRD-PARTY-LICENSES.md` | reqwest / lofty / RustCrypto |
| Subsonic（Go + Rust） | `app/core/subsonic/THIRD-PARTY-LICENSES.md` | 转码器 / Go 依赖 |

第三方依赖按各自许可证引入（含 Permissive 与 LGPL-2.1+/MPL-2.0 等 weak-copyleft，逐项见上表各模块 `THIRD-PARTY-LICENSES.md`），并在各自条款下与本项目 AGPL-3.0 代码共存。本声明为项目维护者的合理努力整理，不构成法律意见。

### 2. 未来许可证升级策略（AGPL-v4 及以后）

> 这是一项**长期许可策略声明**，写入仓库以避免后续版本升级时的法律与贡献者授权争议。

#### 2.1 原则

1. **当前（2026-08）为 AGPL-3.0-or-later**：本项目**自研 / 贡献代码**（含当前发布的二进制中对应自研部分与历史提交）以 **AGPL-3.0 及任何后续版本** 为准（已包含 "or any later version" 弹性条款）；第三方、移植与参考实现代码不受本升级策略影响，按各自许可继续适用（见各模块 `THIRD-PARTY-LICENSES.md`）。
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

升级不是必然发生的。预计在以下至少两项条件成熟时考虑启动升级流程：

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
- 严禁引入 GPL-2.0-only（缺少 "or later version"）等与 AGPL 不兼容的代码；
- 严禁引入 **SSPL / BSL / SSPL / 商业源可用但禁止商业使用** 以及各类源码可用但非OSI/FSF认可的许可（自定义禁止商业使用协议等）的代码链接进本项目；
  > 备注：仅作为完全独立外部工具、不构成衍生作品的脚本不在此限制，但原则上也不建议合入主仓库。
- 所有引入的第三方代码必须在**对应模块**的 `THIRD-PARTY-LICENSES.md` 中逐项列明（包括上游来源、许可证、版权、涉及的模块与文件范围）。

---

## 第三方声明

详细第三方依赖清单与许可证见各子模块内的 `THIRD-PARTY-LICENSES.md`。

**字体资源许可**（`app/assets/fonts/`）：

| 字体 | 文件 | 许可证 | 要点 |
|---|---|---|---|
| Noto Sans CJK SC | `NotoSC-*.otf` | **SIL OFL 1.1** | 开源字体，可自由使用、修改、分发 |
| MiSans | `MiSans-*.ttf` | 小米《[MiSans 字体知识产权许可协议](https://hyperos.mi.com/font-download/MiSans%E5%AD%97%E4%BD%93%E7%9F%A5%E8%AF%86%E4%BA%A7%E6%9D%83%E8%AE%B8%E5%8F%AF%E5%8D%8F%E8%AE%AE.pdf)》（**非 OFL**） | 免费商用；须在软件中注明使用 MiSans；禁止改编/二次开发字体；禁止单独分发字体文件 |
| HarmonyOS Sans SC | `HarmonyOS_Sans_SC_*.ttf` | 华为《[HarmonyOS Sans 字体许可协议](https://gitcode.com/openharmony/global_system_resources/blob/master/LICENSE_Fonts)》（**非 OFL**） | 免费商用；须突出显示使用 HarmonyOS Sans；禁止修改字体；禁止单独分发字体 |
| EtaIcons（自建图标字体） | `EtaIcons.ttf` | 字形来源 **mingcute icons（Apache-2.0）** 为主、**Tabler Icons（MIT）** / **Lucide（ISC）** 补入（`added/`） | 对源图标做**改作**：描边(stroke)SVG 经描边转轮廓后重打包为字体；来源与修改说明见下方「特别鸣谢」及 `app/eta-tools/eta_icons/` |
| EtaMark（自建品牌标识字体） | `EtaMark.ttf` | 字形源自项目自有品牌标识（logo-trim.png 转黑白矢量） | 自建字形，无第三方字体许可义务；源图与生成见 `app/eta-tools/eta_mark/` |

---

## 特别鸣谢（Acknowledgements）

**设计思路借鉴**（本项目在架构设计与实现思路上受到以下开源项目的启发与支持）：

- **[SPlayer-Next](https://github.com/SPlayer-Dev/SPlayer-Next)** —— 混合架构播放器设计、音频引擎管线与在线平台接入的整体思路
- **[KuGouMusicApi](https://github.com/MakcRe/KuGouMusicApi)（MIT）** —— 酷狗平台接口调研与协议思路
- **[NeteaseCloudMusicApi](https://github.com/Binaryify/NeteaseCloudMusicApi)（MIT）** —— 网易云平台接口流程思路
- **[ncm-api-rs](https://github.com/SPlayer-Dev/ncm-api-rs)（WTFPL）** —— Rust 化签名实现方案
- **[MoeKoeMusic](https://github.com/MoeKoeMusic/MoeKoeMusic)** —— 开源高颜值酷狗第三方客户端，桌面端体验与平台接入思路
- **[Mineradio](https://github.com/XxHuberrr/Mineradio)** —— Windows 桌面沉浸式音乐播放器，歌词舞台与视觉呈现思路

**代码 / 参考实现致谢**（audio-engine 与 Zig 解码内核所依赖、参考或移植的第三方组件，许可证逐项见各模块 `THIRD-PARTY-LICENSES.md`）：

- **[AMLL（Apple Music-like Lyrics）](https://github.com/Steve-xmh/applemusic-like-lyrics)（MIT）** —— Apple Music 风格动态歌词引擎参考（歌词墙整墙滚动、逐字扫光、行级弹簧等观感的原创来源；本项目经 SPlayer-Next 的移植稿为对照，以 Dart 重实现）
- **[FFmpeg](https://ffmpeg.org)（LGPL-2.1+）** —— 主解码 / 重采样引擎，多格式移植的参考源
- **[Opus / libopus](https://opus-codec.org)（BSD-3-Clause，IETF RFC 6716）** —— SILK/CELT 移植与静态模式表参考
- **[miniaudio](https://github.com/mackron/miniaudio)（MIT-0 / Public Domain）** —— 通用跨平台音频输出（David Reid）
- **[signalsmith-stretch](https://github.com/Signalsmith-Audio/signalsmith-stretch)（MIT）** —— 变速变调核心（Signalsmith Audio）
- **[minimp3](https://github.com/lieff/minimp3)（CC0-1.0）** —— MP3 Layer III 解码表参考（lieff）
- **[stb_vorbis](https://github.com/nothings/stb)（Public Domain / MIT-0）** —— Ogg Vorbis 解码（Sean Barrett）
- **[kissfft](https://github.com/mborgerding/kissfft)（BSD-3-Clause）** —— Opus CELT FFT/MDCT 参考（Mark Borgerding）
- **[WavPack](https://www.wavpack.com)（BSD-3-Clause）** —— WavPack 解码参考（David Bryant）
- **dsd2pcm（BSD）** —— DSD→PCM 算法参考（Sebastian Gesemann，经 FFmpeg `dsd.c` 对照）
- **[OpenCORE / PV-AMR](https://android.googlesource.com/platform/external/opencore)（Apache-2.0）** —— AMR-NB 解码 vendored 源（Android OpenCORE + OSCL shim）

> 特别说明：以上分别表达对相关项目设计思路的认可、采纳与致谢，以及对所依赖/参考第三方组件作者的感谢；完整的许可义务与声明以仓库及各模块的 `LICENSE` / `THIRD-PARTY-LICENSES.md` 为准。

**图标资源致谢（UI 图标为二改后自建字体打包）**：

- **[MingCute Icons](https://github.com/mingcute-design/mingcute-icons)（Apache-2.0）** —— 本项目界面图标的**主体字形来源**（regular / filled 双风格）。本项目将所需图标自源 SVG 中挑选并按「Material 语义」映射后，对描边风格 SVG 做**描边转轮廓（stroke→outline）改作**，与实心字形一同重打包为自建字体 `EtaIcons`；定稿子集、映射表与生成脚本见 `app/eta-tools/eta_icons/`
- **[Tabler Icons](https://tabler.io/icons)（MIT）** —— 少量 mingcute 缺失语义图标的补入来源（`EtaIcons` 内 `abc / highQuality / deselect` 等 7 项，见 `app/eta-tools/eta_icons/source/added/`），同按 24×24 / 2px 描边规格归一化
- **[Lucide](https://lucide.dev)（ISC）** —— 少量 mingcute/Tabler 均缺失语义图标的补入来源（`EtaIcons` 内 `memoryStickOutline` 等，见 `app/eta-tools/eta_icons/source/added/`），同按 24×24 / 2px 描边规格归一化
- **[line-md（Line MD icons）](https://github.com/cyberalien/line-md)（MIT，Copyright 2020 Vjacheslav Trushkin）** —— 播放器动画字形（play↔pause、downloading/loading 等）的离线设计参考；**未打包进字体**，动画在 Dart 侧以原生实现复刻

> 上述图标的再分发/改作均依据各自许可条款执行；mingcute Apache-2.0 与 Tabler/line-md MIT、Lucide ISC 均允许随本项目（AGPL-3.0）以二进制字体形式分发并保留本声明。

---

## 联系与贡献

- 仓库：<https://github.com/BetaStudio2/ArchoeraMusic>

贡献前请阅读 **[CONTRIBUTING.md](CONTRIBUTING.md)（开发规范）** 与 [docs/architecture.md](docs/architecture.md) 中的实施路线与技术戒律。PR 合入前需要通过签名或显式确认接受上文「贡献者授权」条款。
