# 许可与授权（Licensing）

> **本文件必须严格遵守。若对许可证有任何疑问，请先咨询再修改或分发。**
> 面向使用者的软件声明见 [software-declaration.md](software-declaration.md)，
> 隐私说明见 [privacy.md](privacy.md)。

## 使用声明（太长不看版）

本项目自研代码以 **AGPL-3.0-or-later** 开源。
**AGPL 认可开源商业化**：在遵守其义务（分发或提供网络服务时以 AGPL 开放源码、保留声明并标注修改）的前提下，
自由使用、学习、修改与再分发（包括商业用途）均被许可；**AGPL 不认可闭源商业化**——不开放源码的
闭源集成、换壳/套壳再分发、不开放源码的商业托管/网络服务等不在授权范围内，本项目也不提供闭源商业授权。
**自愿打赏不构成授权，也不构成商业合作**（详见 §3）。
本声明仅为开发者对授权边界的说明，法律层面以仓库根 `LICENSE`（AGPL-3.0-or-later）为准。

## 1. 当前许可证

本项目整体以 **GNU Affero General Public License, version 3（AGPL-3.0）** 发布（许可证正文见仓库根 [LICENSE](../LICENSE)），并采用 **AGPL-3.0-or-later** 弹性授权策略（含 "or any later version" 条款；不再另行规划许可证版本升级）。

- **版权持有者**：BetaStudio2
- **起始许可版本**：AGPL-3.0（`AGPL-3.0-or-later`，含后续版本弹性条款）
- **代码归属**：本项目**自研 / 贡献代码**由本仓库作者与贡献者编写；第三方、移植与参考实现代码按各自来源与许可登记（见各模块 `THIRD-PARTY-LICENSES.md`），本项目不对其主张为自有编写。

### 各原生模块的声明

每个原生子模块内均带有 `THIRD-PARTY-LICENSES.md`，列清单个直接/间接依赖：

| 模块 | 位置 | 备注 |
|---|---|---|
| C 音频引擎 | `app/core/audio-engine/THIRD-PARTY-LICENSES.md` | miniaudio / FFmpeg 等 |
| 扫描器（C#） | `app/core/scanner/THIRD-PARTY-LICENSES.md` | TagLibSharp / SQLitePCLRaw |
| 本地搜索索引器（C#） | `app/core/indexer/THIRD-PARTY-LICENSES.md` | ToolGood.Words / SQLitePCLRaw / Microsoft.Data.Sqlite；数据表 `nfkc.tsv` / `accent_fold.tsv` / `variant_fold.tsv` / `def_en2hanzi.tsv` / `def_hanzi2en.tsv` / `ja_readings.tsv` 派生自 Unicode（Unicode License，含 Unihan `kDefinition` / `kJapanese` / `kSimplifiedVariant` + `kJapaneseOldVariant`、以及 NFD 规范分解）；`kana_romaji.tsv` 为自研（标准罗马字事实） |
| 刮削器（C++） | `app/core/scraper/THIRD-PARTY-LICENSES.md` | TagLib / nlohmann-json |
| Subsonic（Go + Rust） | `app/core/subsonic/THIRD-PARTY-LICENSES.md` | 转码器 / Go 依赖 |

第三方依赖按各自许可证引入（含 Permissive 与 LGPL-2.1+/LGPL-3.0+/MPL-2.0 等 weak-copyleft，
以及同为 AGPLv3 系的 AGPL-3.0-only 上游移植，如 AMLL 歌词引擎），逐项见上表各模块
`THIRD-PARTY-LICENSES.md` 与 [acknowledgements.md](acknowledgements.md)，并在各自条款下与本项目 AGPL-3.0 代码共存。本声明为项目维护者的合理努力整理，不构成法律意见。

## 2. 贡献者授权与第三方代码约束

> 历史说明：项目曾预留「未来许可证升级策略（AGPL-v4 及以后）」，该策略已取消并归档至
> [archive/agpl-v4-upgrade-policy.md](archive/agpl-v4-upgrade-policy.md)。项目现行许可仍为
> **AGPL-3.0-or-later**，但不再主动规划或公告升级到后续版本。

### 2.1 贡献者授权（Contributor License Grant）

任何向本仓库提交代码（PR / patch / 直接推送）的贡献者，被视为已同意以下不可撤销授权：

> **本人（贡献者）特此授权版权持有者 BetaStudio2，将本人贡献的代码，连同项目整体，
> 以「AGPL-3.0-or-later」进行再许可、分发与修改。该授权在全球范围内、永久、不可撤销、免版税。**

贡献者在本项目的个人署名权将被保留（git author / changelog 等），但不影响上述再许可授权。

### 2.2 第三方代码的约束

- 任何**第三方引入代码**（PR 合入的外部代码 / 上游移植）必须携带与 AGPL-3.0 **兼容**的许可证；
- 严禁引入 GPL-2.0-only（缺少 "or later version"）等与 AGPL 不兼容的代码；
- 严禁引入 **SSPL / BSL / SSPL / 商业源可用但禁止商业使用** 以及各类源码可用但非OSI/FSF认可的许可（自定义禁止商业使用协议等）的代码链接进本项目；
  > 备注：仅作为完全独立外部工具、不构成衍生作品的脚本不在此限制，但原则上也不建议合入主仓库。
- 所有引入的第三方代码必须在**对应模块**的 `THIRD-PARTY-LICENSES.md` 中逐项列明（包括上游来源、许可证、版权、涉及的模块与文件范围）。
- **UI 设计规格（[ArchoeraMusic-UI](https://github.com/ArchoeraC/ArchoeraMusic-UI)）**：现行版本为 **MIT**，早期版本为 **AGPL-3.0-or-later**（按所钉 commit 的 `LICENSE` 判定）。MIT 允许复制、修改、合并、再许可与分发，与本仓库 AGPL-3.0-or-later 兼容；复制其内容时唯一硬性义务是保留版权与许可声明（登记 [acknowledgements.md](acknowledgements.md) 属溯源惯例，非许可条件）。反向：AGPL 代码放进 MIT 仓库不会变成 MIT，含 AGPL 代码的分发须整体满足 AGPL；要保持该仓库纯 MIT 就不要混入。另注意 MIT 不改变应用源码 / 品牌 / 字体 / 封面美术的许可。边界见 [ui-design-baseline.md](ui-design-baseline.md)。

## 3. 打赏与商业合作（不构成授权）

本项目接受**自愿打赏**。打赏是**无偿赠与**，且**不构成**下列任何一项：

- **不构成授权**：不授予 AGPL-3.0-or-later 之外的任何许可权利，不构成闭源商业授权、
  版权转让或再许可。任何人使用本项目的授权范围**始终完全由 `LICENSE` 决定**，
  与是否打赏无关。
- **不构成商业合作**：不构成赞助、广告投放、推广位、联名、技术服务合同、定制开发
  或任何形式的对价关系。本项目**不接受**以「换取功能 / 授权 / 优先级 / 定制 / 免责」
  为条件的付款，也不接受赞助内容注入。
- **不影响项目行为**：打赏不影响功能开放与否、issue / PR 的处理顺序、发布节奏，
  也不影响项目对任何第三方（含音乐平台方）的立场。
- **不附带义务**：作者对打赏者不承担额外的支持、维护、交付或 SLA 义务；
  打赏者亦不得据此主张任何权利。

打赏款项不予退还（法律强制规定除外），**请思考后量力而行**。若你希望以商业方式使用本项目，
请直接依 `LICENSE`（AGPL-3.0-or-later）履行义务，**无需（也不应）**通过打赏获取授权。

> 打赏渠道以 [README](../README.md)「支持项目」小节与项目主页公告为准。
