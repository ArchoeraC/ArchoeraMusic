# 许可与授权（Licensing）

> **本文件必须严格遵守。若对许可证有任何疑问，请先咨询再修改或分发。**
> 面向使用者的软件声明见 [software-declaration.md](software-declaration.md)，
> 隐私说明见 [privacy.md](privacy.md)。

## 使用声明（太长不看版）

本项目自研代码以 **AGPL-3.0-or-later** 开源。
**AGPL 认可开源商业化**：在遵守其义务（分发或提供网络服务时以 AGPL 开放源码、保留声明并标注修改）的前提下，
自由使用、学习、修改与再分发（包括商业用途）均被许可；**AGPL 不认可闭源商业化**——不开放源码的
闭源集成、换壳/套壳再分发、不开放源码的商业托管/网络服务等不在授权范围内，本项目也不提供闭源商业授权。
本声明仅为开发者对授权边界的说明，法律层面以仓库根 `LICENSE`（AGPL-3.0-or-later）为准。

## 1. 当前许可证

本项目整体以 **GNU Affero General Public License, version 3（AGPL-3.0）** 发布（许可证正文见仓库根 [LICENSE](../LICENSE)），并采用 **AGPL-3.0-or-later** 弹性授权策略（含 "or any later version" 条款，升级触发与流程见下文「未来许可证升级策略」）。

- **版权持有者**：BetaStudio2
- **起始许可版本**：AGPL-3.0（`AGPL-3.0-or-later`，含后续版本弹性条款）
- **代码归属**：本项目**自研 / 贡献代码**由本仓库作者与贡献者编写；第三方、移植与参考实现代码按各自来源与许可登记（见各模块 `THIRD-PARTY-LICENSES.md`），本项目不对其主张为自有编写。

### 各原生模块的声明

每个原生子模块内均带有 `THIRD-PARTY-LICENSES.md`，列清单个直接/间接依赖：

| 模块 | 位置 | 备注 |
|---|---|---|
| C 音频引擎 | `app/core/audio-engine/THIRD-PARTY-LICENSES.md` | miniaudio / FFmpeg 等 |
| 扫描器（C#） | `app/core/scanner/THIRD-PARTY-LICENSES.md` | TagLibSharp / SQLitePCLRaw |
| 刮削器（C++） | `app/core/scraper/THIRD-PARTY-LICENSES.md` | TagLib / nlohmann-json |
| 下载引擎（Rust） | `app/core/downloader/THIRD-PARTY-LICENSES.md` | reqwest / lofty / RustCrypto |
| Subsonic（Go + Rust） | `app/core/subsonic/THIRD-PARTY-LICENSES.md` | 转码器 / Go 依赖 |

第三方依赖按各自许可证引入（含 Permissive 与 LGPL-2.1+/MPL-2.0 等 weak-copyleft，逐项见上表各模块 `THIRD-PARTY-LICENSES.md`），并在各自条款下与本项目 AGPL-3.0 代码共存。本声明为项目维护者的合理努力整理，不构成法律意见。

## 2. 未来许可证升级策略（AGPL-v4 及以后）

> 这是一项**长期许可策略声明**，写入仓库以避免后续版本升级时的法律与贡献者授权争议。

### 2.1 原则

1. **当前（2026-08）为 AGPL-3.0-or-later**：本项目**自研 / 贡献代码**（含当前发布的二进制中对应自研部分与历史提交）以 **AGPL-3.0 及任何后续版本** 为准（已包含 "or any later version" 弹性条款）；第三方、移植与参考实现代码不受本升级策略影响，按各自许可继续适用（见各模块 `THIRD-PARTY-LICENSES.md`）。
2. **自动升级机制**：由于采用 `AGPL-3.0-or-later`，当 FSF 发布新版 AGPL（如 AGPL-4.0 及以后）时，项目**自动适用**新版本条款，无需逐位贡献者另行授权、也无需版权持有者逐一征询。正式的版本切换按 §2.4 流程执行，以保证透明与可追溯：
   - 切换时以 **BetaStudio2 官方公告 + 仓库根 LICENSE 正文更新 + 提交签名** 为准；
   - 切换后新的 AGPL 版本条款 **立即适用于切换提交及之后所有代码**；
   - 历史提交仍按其提交时的许可证版本保留不变（不追溯）。

### 2.2 贡献者授权（Contributor License Grant）

任何向本仓库提交代码（PR / patch / 直接推送）的贡献者，被视为已同意以下不可撤销授权：

> **本人（贡献者）特此授权版权持有者 BetaStudio2，将本人贡献的代码，连同项目整体，一并以"AGPL-3.0 及任何更高版本的 GNU Affero General Public License"进行再许可、分发与修改。该授权在全球范围内、永久、不可撤销、免版税。**

这意味着：

- 由于项目已采用 `AGPL-3.0-or-later`，未来 FSF 发布新版 AGPL（如 **AGPL-4.0**）后，**所有历史贡献将自动被纳入新版本授权范围**，贡献者不得另行主张或拒绝；
- 贡献者在本项目的个人署名权将被保留（git author / changelog 等），但不影响上述再许可授权。

### 2.3 升级到 AGPL-v4 的触发条件（非承诺，仅为指引）

升级不是必然发生的。预计在以下至少两项条件成熟时考虑启动升级流程：

- GNU 官方正式发布 **AGPL-4.0** 并获得社区广泛采用；
- AGPL-4.0 对 AI / LLM 训练场景、SaaS / 云端托管场景、或 DRM / 签名校验绕开等问题有更明确的条款补强；
- 出现需要新条款来保护用户自由或项目生态的新情况（如云厂商闭源改造但不释放源码等）。

### 2.4 升级流程（预先约定）

1. **公告期（不少于 30 天）**：在 GitHub Issue / 社区渠道发布升级提案，列明原因、新条款差异点，并接受贡献者反馈；
2. **切换 LICENSE 正文**：将仓库根 LICENSE 替换为新版 AGPL 官方正文；
3. **同步更新本节**：本文件的许可条款段落明确"自 commit `<hash>` 起，项目切换到 AGPL-x.y"；
4. **版权年度更新**：同步更新版权年份与版权持有者署名（如有必要）；
5. **推送签名提交**：升级提交必须由 BetaStudio2 官方 GPG / SSH 签名密钥签名。

### 2.5 第三方代码的约束

- 任何**第三方引入代码**（PR 合入的外部代码 / 上游移植）必须携带与 AGPL-3.0（及未来 AGPL-4.0）**兼容**的许可证；
- 严禁引入 GPL-2.0-only（缺少 "or later version"）等与 AGPL 不兼容的代码；
- 严禁引入 **SSPL / BSL / SSPL / 商业源可用但禁止商业使用** 以及各类源码可用但非OSI/FSF认可的许可（自定义禁止商业使用协议等）的代码链接进本项目；
  > 备注：仅作为完全独立外部工具、不构成衍生作品的脚本不在此限制，但原则上也不建议合入主仓库。
- 所有引入的第三方代码必须在**对应模块**的 `THIRD-PARTY-LICENSES.md` 中逐项列明（包括上游来源、许可证、版权、涉及的模块与文件范围）。
