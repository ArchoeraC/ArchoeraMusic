# 第三方许可与 AGPL 兼容性审计（2026-11）

> 范围：`docs/acknowledgements.md`「特别鸣谢」所列项目，以及音频引擎
> （内部代号 **EraAudio** / `app/core/audio-engine`）的解码内核。
> 结论用于工程自查，**不构成法律意见**；最终以上游许可原文为准。

## 结论摘要

| 类别 | 项目 | 许可 | 与 AGPL-3.0 的关系 | 处置 |
|---|---|---|---|---|
| 直接依赖 | FFmpeg（纯 LGPL 构建） | LGPL-3.0-or-later（Linux/macOS）/ LGPL-2.1-or-later（Windows） | ✅ 可聚合；须保留声明、提供源码/可重链 | 已登记；构建脚本与补丁随仓库 |
| 直接依赖 | libopus / miniaudio / signalsmith-stretch | BSD-3 / MIT-0 / MIT | ✅ | 已登记 |
| 内核移植 | FFmpeg `libavcodec`/`libavformat` → Zig | LGPL-2.1-or-later | ✅（衍生部分仍为 LGPL） | **本次修正文件头 SPDX + 溯源** |
| 内核移植 | libopus（SILK / kissfft / 静态模式表） | BSD-3-Clause | ✅（须保留版权声明） | **本次修正文件头 SPDX + 版权行** |
| 内核移植 | WavPack / dsd2pcm | BSD-3 / BSD | ✅ | **本次修正文件头 SPDX** |
| 数据转录 | minimp3 解码表 | CC0-1.0 | ✅ | **本次修正文件头 SPDX** |
| vendored | stb_vorbis / OpenCORE AMR | PD / Apache-2.0 | ✅ | 保留原文件头 |
| 思路参考 | denial（GPL-3.0-or-later） | GPL-3.0+ | ✅（GPLv3 系可与 AGPLv3 聚合），且**未复制代码** | 仅文档致谢 |
| 思路参考 | SPlayer-Next（AGPL-3.0）、NekoMusic API（AGPL-3.0 + §7 附加条款） | AGPL-3.0 | ✅；Neko 须署名 | 已在其「关于」页署名 |
| 思路参考 | **MoeKoeMusic（GPL-2.0-only）** | GPL-2.0-only | ❌ **不可合并**（AGPL-3.0 与 GPL-2.0-only 不兼容） | **本次移除代码级引用，改按公开行为独立实现** |
| 思路参考 | **Mineradio（未声明许可）** | 无许可 | ⚠ 默认「保留所有权利」 | **仅思路，未复制代码/素材；文档已注明** |

**总体判断**：项目仍可作为 **AGPL-3.0 聚合作品**分发。需要保证的是：

1. 第三方代码（尤其 LGPL/BSD 部分）**保留原许可与版权声明**，不能被吞成纯 AGPL；
2. **GPL-2.0-only / 无许可项目不得有代码级复制**；
3. 各模块的第三方清单与实际依赖一致。

## 本次发现与修复

### 1. 音频内核：衍生文件被标成纯 AGPL（高）

`kernel/` 下 223 个 `.zig` 文件此前统一标注
`SPDX-License-Identifier: AGPL-3.0-or-later`，但其中 90 个文件在注释中明确写着
「逐位移植 / 逐句对齐 FFmpeg」「libopus 移植」「WavPack 对照」「minimp3 表转录」。
把 LGPL 衍生作品标成纯 AGPL 不符合 LGPL 的 copyleft 要求，也不满足 BSD-3
「保留版权声明」的义务。

修复：

- 按 `THIRD-PARTY-LICENSES.md` 的分类 + 文件头自述，给 90 个衍生文件改为对应 SPDX：
  - FFmpeg 移植 → `LGPL-2.1-or-later`
  - libopus / WavPack → `BSD-3-Clause`（文件头补上游版权行）
  - minimp3 表 → `CC0-1.0`
- 文件头增加「衍生作品」说明，指向模块 `THIRD-PARTY-LICENSES.md`；
- 模块文档新增「文件级许可标注（SPDX）」一节，明确**以文件头为准**；
- 第二轮复核把文档原归入「对照参考」、但文件头明确写「移植 / 逐位复刻 / 位级一致 /
  表值来自 FFmpeg」的模块一并补标：FLAC、DTS、MLP、APE、ALAC、AAC PS/SBR 表、
  Opus CELT/PVQ/RC/FFT、WMA ASF 容器与 MDCT；
- 仍属独立实现的文件保持 `AGPL-3.0-or-later`（MP3 码流层、WAV/AIFF、Ogg/M4A/mka
  容器、probe/takeover、DSP 等）。

> LGPL-2.1-or-later 本身允许按更高版本行使权利，与 AGPL-3.0 聚合分发兼容；
> 静态合并部分继续按模块文档提供完整源码与构建链以满足「可重链」要求。

### 2. KG 模块：引用了 GPL-2.0-only 项目的实现路径（高）

`app/lib/services/kugou/*` 多处注释写着「对齐 MoeKoeMusic `deviceUtil.js` /
`Library.vue` / `formatPlaylistTracks`」。MoeKoeMusic 的 `package.json` 声明
`GPL-2.0-only`，与 AGPL-3.0 **不兼容**，这类代码级引用会让人合理怀疑存在复制。

核查结果：

- 设备身份（GUID / MID / DEV / WebGL）算法实际来自 **KuGouMusicApi（MIT）**
  `util/util.js`（`randomString` / `calculateMid` / `getGuid` /
  `generateWebGLHash`），字段与取值约定相同；
- 其余引用均为接口字段/排序/分页行为的描述，属于可独立实现的接口事实。

修复：

- 代码注释删除对 MoeKoeMusic 的路径级引用，改为「接口实际行为」描述；
- 设备身份注释改为归因 **KuGouMusicApi（MIT）**；
- `docs/acknowledgements.md` 明确标注 MoeKoeMusic 为 GPL-2.0-only、仅参考公开行为、
  未复制代码，并说明 GPL-2.0-only 与 AGPL-3.0 不兼容；
- Mineradio 标注「未声明开源许可」，注明未复制代码或美术资源。

### 3. 模块第三方清单缺失（中）

- 新增 `app/core/vault-rs/THIRD-PARTY-LICENSES.md`（RustCrypto / BSD / MIT，全部兼容）；
- 新增 `app/core/audio-engine/tempo-rs/THIRD-PARTY-LICENSES.md`
  （signalsmith-stretch / dasp / 构建期 bindgen 等）；
- 纠正 tempo-rs 的「唯一依赖」表述（实际含 dasp、bindgen 等构建期依赖）。

### 4. 未发现的问题

- 未在代码中发现 denial / Xapian / Baloo / Groonga / TTALib / TAK 等 GPL/LGPL
  参考实现的源码复制；TTA / TAK / Shorten 的实现均沿 FFmpeg（LGPL）通道，
  与模块文档一致；
- 未发现 Mineradio 的代码或美术资源；
- NekoMusic 音源为公开 HTTP 互操作，且「设置 → 关于」已包含其要求的署名文案。

## 后续维护要求

1. 新增任何「移植 / 转录 / vendored」文件时，**文件头 SPDX 必须写上游许可**，
   并在模块 `THIRD-PARTY-LICENSES.md` 登记来源文件；
2. 只允许引入 LGPL-2.1+ / LGPL-3+ / BSD / MIT / Apache-2.0 / CC0 / PD 来源；
   **GPL-2.0-only、无许可项目一律只可参考思路，禁止复制代码/素材**；
3. 发布包 `licenses/` 与 `THIRD-PARTY-NOTICES.md` 需随新依赖同步更新；
4. 若日后有文件被认定为衍生而当前标为 AGPL，按上游许可补标即可，不影响整体分发。
