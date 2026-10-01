# 第三方声明与特别鸣谢

> 随发布产物内嵌的运行库许可与源码获取方式见根 [THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md)；
> 各原生模块的直接依赖逐项见对应模块的 `THIRD-PARTY-LICENSES.md`。

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

## 特别鸣谢（Acknowledgements）

**设计思路借鉴**（本项目在架构设计与实现思路上受到以下开源项目的启发与支持）：

- **[KuGouMusicApi](https://github.com/MakcRe/KuGouMusicApi)（MIT）** —— 酷狗平台接口调研与协议思路
- **[NeteaseCloudMusicApi](https://github.com/Binaryify/NeteaseCloudMusicApi)（MIT）** —— 网易云平台接口流程思路
- **[ncm-api-rs](https://github.com/SPlayer-Dev/ncm-api-rs)（WTFPL）** —— Rust 化签名实现方案
- **[MoeKoeMusic](https://github.com/MoeKoeMusic/MoeKoeMusic)** —— 开源高颜值酷狗第三方客户端，桌面端体验与平台接入思路
- **[Mineradio](https://github.com/XxHuberrr/Mineradio)** —— Windows 桌面沉浸式音乐播放器，歌词舞台与视觉呈现思路
- **[NekoMusic / Neko 歌姬计划](https://github.com/FantasyNetworkCN/NekoMusicDocs)（服务端 GPL-3.0；PC 客户端 AGPL-3.0 并附 AGPLv3 §7 附加条款）** ——
  **实验性第三方音源**（登录 / 搜索 / 收藏 / 歌单 / 直链 / 歌词）的 API 契约来源。本项目**仅经其公开 HTTP API 互操作，
  未复制或链接其源代码**（下载扩展名按文件头魔数自行实现）；并依其附加条款在「设置 → 关于」页署名
  「本程序由 Neko 歌姬计划 API 提供技术支持」、给出本项目仓库与 [其 API 文档](https://github.com/FantasyNetworkCN/NekoMusicDocs) 链接。
  该音源**默认关闭**，仅用户显式开启后才会请求。

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
