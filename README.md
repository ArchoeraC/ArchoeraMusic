<p align="center">
  <img src="logo.png" width="128" height="128" alt="ArchoeraOS">
</p>

# ArchoeraOS

> 别骂了，作者偶尔精神不正常不是挺正常的（
> 一个把音乐播放器当操作系统的恶趣味实验——装在桌面上叫播放器，接管显卡和输入设备就叫系统了。

> [!CAUTION]
> **Caution**：本分支纯属娱乐项目，只是用于抨击部分过度代码洁癖而“清理一切不必要东西”等过度的行为。
> 即使可以正常使用，也非常不建议作为主力机（你还要当主力机？！）食用。
> 说具体点：这里没有桌面环境、没有窗口管理、没有托盘，只有一个全屏播放器，和一层为了让它成为“系统”而写出来的合成器。

<p align="center">
  <img src="screenshot.png" width="720" alt="ArchoeraOS：播放器即系统界面">
</p>

---

## 目录

1. [项目简介](#项目简介)
2. [系统构成](#系统构成)
3. [关键设计](#关键设计)
4. [项目结构](#项目结构)
5. [构建与运行](#构建与运行)
6. [文档](#文档)
7. [许可证（Licensing）](#许可证licensing)
8. [第三方声明](#第三方声明)
9. [特别鸣谢（Acknowledgements）](#特别鸣谢acknowledgements)
10. [联系与贡献](#联系与贡献)

---

## 项目简介

**ArchoeraOS** 是本仓库的**会话层分支**：把播放器从「桌面上运行的一个应用」变成「整机唯一的界面」。
播放器本体（Flutter + GTK3）与上游 `main` 完全一致，区别在于它在这里跑在自研合成器之上、以全屏
kiosk 客户端的身份存在，并通过自定义协议驱动会话级能力。

- **自研 kiosk 合成器**（`os/archoera-shell`，Rust + smithay）：直接接管 DRM/KMS、libinput、libseat，
  不经 Plasma / KWin / X11；单客户端、单输出、无窗口装饰。
- **自定义会话协议 `archoera_shell_v1`（v3）**：播放器向合成器请求关机/重启/挂起、亮度、屏幕开关与
  运行时显示设置（缩放/分辨率/旋转），并接收媒体键、电源键、电池、会话状态与主输出状态。
- **平台能力桥接 `apl_*`（C ABI）**：会话、电源防休眠、系统媒体会话、窗口状态、系统主题色/深浅色、
  系统资源与蓝牙状态——零 JSON、零子进程、同进程动态链接（`app/native/platform`）。
- **默认用户 `archoera`**：普通用户 + `libseat → systemd-logind` 的 VT 会话授权，DRM/输入设备全链路
  **不提权**；家目录承载偏好、媒体库、下载与输入法配置。
- **最小镜像 `os/vm/`（mkosi + QEMU/KVM）**：一条命令构建可引导镜像并启动 VM，用于验证真实
  DRM/KMS 通路（虚拟 GPU 上同样跑通出图、光标与输入法）。

> **使用声明（太长不看版）**：本项目自研代码以 **AGPL-3.0-or-later** 开源。
> **AGPL 认可开源商业化**：在遵守其义务（分发或提供网络服务时以 AGPL 开放源码、保留声明并标注修改）的前提下，
> 自由使用、学习、修改与再分发（包括商业用途）均被许可；**AGPL 不认可闭源商业化**——不开放源码的
> 闭源集成、换壳/套壳再分发、不开放源码的商业托管/网络服务等不在授权范围内，本项目也不提供闭源商业授权。
> 本声明仅为开发者对授权边界的说明，法律层面以根目录 `LICENSE`（AGPL-3.0-or-later）为准。

---

## 系统构成

```
┌────────────────────────────────────────────────────────────────────┐
│ ArchoeraMusic（Flutter + GTK3）  ← 唯一界面：全屏 kiosk 客户端       │
│   播放 / 媒体库 / 设置（含「系统」分区与系统监视器）/ 歌词 / 频谱        │
└───────────────┬───────────────────────────────┬────────────────────┘
                │ Wayland                        │ apl_* C ABI（FFI 直连）
                │ xdg-shell · dmabuf · 光标形状     │
                │ 分数缩放 · text-input/IME        │
┌───────────────┴───────────────────┐  ┌────────┴──────────────────────┐
│ os/archoera-shell（Rust + smithay）│  │ app/native/platform（C++/ObjC++）│
│  ├─ kiosk 策略：单窗口全屏、无装饰  │  │  会话（archoera_shell_v1 客户端）│
│  ├─ DRM/KMS + EGL/GBM 直接扫描输出 │  │  电源防休眠 / 系统媒体会话      │
│  ├─ libinput + libseat(logind)     │  │  窗口状态 / 系统主题色与深浅色   │
│  ├─ archoera_shell_v1 服务端（v3） │  │  系统资源 / 蓝牙（BlueZ）       │
│  ├─ 光标 / 输入法 / 分数缩放协议   │  └───────────────────────────────┘
│  └─ 控制面：logind 电源 / 亮度      │
└───────────────────────────────────┘
```

`os/`（系统会话层）与 `app/`（播放器 + 桥接）是两个独立构建单元：合成器是 Rust workspace，
播放器与桥接是 Flutter/CMake 工程；两者只通过 **Wayland 协议**与 **apl_* C ABI** 通信。

---

## 关键设计

- **普通用户即可（最小权限）**：DRM/输入设备经 `libseat → systemd-logind` 的 VT 会话打开，
  不请求 root、不写系统目录、不安装服务或驱动。
- **没有桌面环境**：不做窗口管理、装饰与托盘；所有 toplevel 一律被配置为输出尺寸 +
  Maximized/Fullscreen，客户端自己负责整个界面。
- **GPU 优先**：dmabuf v4 反馈 + EGL/GBM 扫描输出；视觉重活走 GPU（如播放页水纹为单 pass 着色器），
  重计算与阻塞 IO 下沉原生层/后台 isolate。
- **事件驱动按需重绘**：没有客户端提交时合成器完全空闲，不空转 vblank。
- **协议内省 + 运行时设置**：合成器 bind 时下发当前状态（能力位/亮度/音量/电池/会话/屏幕/输出），
  v3 起 `set_output_scale/mode/transform` 可运行时改显示参数；未置位的请求被静默忽略，保证降级安全。
- **系统能力统一走桥接**：Dart 只调 `apl_*`，不直调平台 API、不起子进程、不解析平台数据。

---

## 项目结构

```
ArchoeraMusic/
├── app/                        # Flutter 应用 + 原生模块（播放器本体）
│   ├── lib/                    # UI / 业务层 / services/platform（apl_* 绑定与外观层）
│   ├── linux|windows|macos/    # 平台壳（Linux 壳在 kiosk 下无装饰）
│   ├── native/platform/        # 平台能力桥接（apl_* C ABI；Linux/macOS/Windows/兜底）
│   └── core/                   # 原生播放栈（audio-engine / scanner / scraper / downloader / subsonic）
├── os/                         # ArchoeraOS 会话层（Rust workspace）
│   ├── archoera-shell/         # kiosk 合成器（winit 嵌套 / udev 裸机）
│   ├── archoera-control/       # 会话协议 CLI（状态查看 / 控制，兼协议端到端验证器）
│   ├── archoera-smoke/         # 最小 Wayland 客户端（合成器冒烟）
│   ├── protocol/               # archoera-shell-v1.xml（协议唯一真源）
│   └── vm/                     # mkosi + QEMU/KVM 最小镜像与工具
└── docs/                       # 会话层 / 桥接 / 渲染 / 架构等设计文档
```

---

## 构建与运行

### 播放器（桌面）

上游形态的完整自编译手册（三端环境、缓存外置、常见问题）见
**[docs/user-build-from-source.md](docs/user-build-from-source.md)**；CI 见 `.github/workflows/`。

```bash
git clone https://github.com/BetaStudio2/ArchoeraMusic.git
cd ArchoeraMusic
flutter pub get --directory app
flutter build linux --release          # 产物：app/build/linux/x64/release/bundle/
```

### 会话层（`os/`，Rust workspace）

```bash
cd os
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
cargo build --release -p archoera-shell --features udev   # 裸机（DRM/KMS + libinput + libseat）
```

`udev` 后端需系统提供 `libseat` / `libinput` / `libdrm` / `gbm` / `libudev` 开发文件；
不启用时仍可用 `winit` 后端嵌套运行在现有桌面会话里（开发/集成测试）。

### 最小镜像与虚拟机（`os/vm/`）

```bash
os/vm/build.sh build    # 构建可引导镜像（mkosi；Format=disk + systemd-boot）
os/vm/build.sh vm       # 构建并启动 QEMU/KVM（自动透传 virtio-gpu / 键盘 / 触摸板）
```

镜像里会话以**默认用户 `archoera`**（uid 1000、`/home/archoera`）运行，日志落在
`~/.local/state/archoera-session.log`；hvc0 为 root 调试口。已验证结果与踩坑记录见
**[os/vm/README.md](os/vm/README.md)**。

---

## 文档

- [ArchoeraOS 会话层设计](docs/archoera-os.md) —— 合成器 / 会话协议 v3 / kiosk 策略 / 默认用户与数据布局
- [平台原生桥接（apl_* C ABI）](docs/platform-native-bridge.md) —— 能力位 / 事件 / 零 JSON / 同进程动态链接
- [平台能力外观层](docs/platform-capability-facade.md) —— Dart 侧能力接口与每平台实现（FFI ⇄ Noop 降级）
- [播放页渲染优化](docs/player-render-optimization.md) —— 水纹着色器与性能预算
- [VM 工具与已验证结果](os/vm/README.md) —— mkosi 镜像 / QEMU / 串口排查 / 缺陷记录
- [用户自编译手册（太长不看版）](docs/user-build-from-source.md) —— 三端从源码构建 / 调试 / 打包 / 缓存外置
- [架构设计](docs/architecture.md) —— 进程模型 / 音频管线 / FFI 桥接
- [eta 图标体系食用说明](app/lib/eta/README.md) —— EtaIcons/EtaMark 引用写法 / 新增字形
- 使用与授权声明见文首；第三方依赖与许可逐项见各模块 `THIRD-PARTY-LICENSES.md`

---

## 许可证（Licensing）

> **本节必须严格遵守。若对许可证有任何疑问，请先咨询再修改或分发。**

### 1. 当前许可证

本项目整体（不包含因封装需要的包括但不限于Linux内核等依赖文件）以 **GNU Affero General Public License, version 3（AGPL-3.0）** 发布（许可证正文见仓库根 [LICENSE](LICENSE)），并采用 **AGPL-3.0-or-later** 弹性授权策略（含 "or any later version" 条款，升级触发与流程见下文「未来许可证升级策略」）。

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

- **[KuGouMusicApi](https://github.com/MakcRe/KuGouMusicApi)（MIT）** —— 酷狗平台接口调研与协议思路
- **[NeteaseCloudMusicApi](https://github.com/Binaryify/NeteaseCloudMusicApi)（MIT）** —— 网易云平台接口流程思路
- **[ncm-api-rs](https://github.com/SPlayer-Dev/ncm-api-rs)（WTFPL）** —— Rust 化签名实现方案
- **[MoeKoeMusic](https://github.com/MoeKoeMusic/MoeKoeMusic)** —— 开源高颜值酷狗第三方客户端，桌面端体验与平台接入思路
- **[Mineradio](https://github.com/XxHuberrr/Mineradio)** —— Windows 桌面沉浸式音乐播放器，歌词舞台与视觉呈现思路

**代码 / 参考实现致谢**（audio-engine 与 Zig 解码内核所依赖、参考或移植的第三方组件，许可证逐项见各模块 `THIRD-PARTY-LICENSES.md`）：

- **[AMLL（Apple Music-like Lyrics）](https://github.com/Steve-xmh/applemusic-like-lyrics)（MIT）** —— Apple Music 风格动态歌词引擎参考（歌词墙整墙滚动、逐字扫光、行级弹簧等观感的原创来源；本项目以 Dart 重实现）
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

贡献前请阅读……还是别想着这个仓库也做贡献了吧……
