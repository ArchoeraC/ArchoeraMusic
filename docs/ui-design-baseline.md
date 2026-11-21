# UI 设计基准（ArchoeraMusic-UI Skill）

> 状态：生效 · 2026-11-21 · 维护者：BetaStudio2
>
> 本文是**界面视觉规格的唯一来源**。与 `CONTRIBUTING.md` §4 #13、`AGENTS.md`
> 「UI 设计基准」配套；与许可条款冲突时以 [licensing.md](licensing.md) / 根 `LICENSE` 为准。

## 1. 硬性结论

1. **设计原型只有一个**：[`ArchoeraC/ArchoeraMusic-UI`](https://github.com/ArchoeraC/ArchoeraMusic-UI)
   （Agent Skill 名 `archoera-music-ui`）。新页面、改版、视觉评审、样式重构都以它的
   `SKILL.md` / `references/` / `assets/tokens.json` 为依据。
2. **禁止把本仓库整套应用代码当 UI 原型**：不照抄 / 反推 `app/lib/**` 现有页面、组件、
   主题常量与动效参数来"设计"新界面；仓库根 `screenshot.png`、`site/` 宣传页与历史
   `docs/architecture.md` §10.7 的 Web/Vue 迁移记录同样只是**现状与沿革**，不是规格。
3. **现有实现只提供行为契约**：数据来源、路由、状态管理、事件总线、FFI 接口按本仓库
   架构走；**视觉 token、尺寸、圆角、间距、层级、动效参数**按 skill 走，两者不混用。
4. **只转译规格，不搬运行时**：落地用 Flutter 原生组件实现；skill 的 HTML / CSS / JS
   是规格与预览载体，不是产品组件。若确实复制其文本 / 代码 / 资源，按 MIT 保留声明即可
   （见 §3），不需要额外授权。

> 为什么：现有界面本身是多次迭代的产物，拿它当原型会把历史偏差固化成"规范"，
> 也会让视觉评审失去可比对的基准。规格与实现分离后，改版才有唯一裁判。

> **适用范围**：本文只约束本仓库（ArchoeraMusic）的界面工作，**不构成**对任何第三方产品、
> fork 或已分离仓库的授权、背书或合规认定；其他项目不得援引本文主张与本项目的关系。

## 2. 使用方式

- 入口读 skill 的 `SKILL.md`（原则、非协商项、工作流、检查清单），按需再读
  `references/tokens.md`、`layout.md`、`components.md`、`player.md`、`motion.md`、`patterns.md`；
  机器可读 token 在 `assets/tokens.json`。
- **版本钉住**：PR / 提交说明中注明所依据的 commit SHA 或 tag；规格升级单独开 PR，
  不在功能 PR 里顺手换基准。
- **覆盖不到的地方**：先用最接近的既有 token / pattern 组合，并在 PR 说明里记录缺口；
  **不得**回头用现有源码"补全"规格。确实需要新增语义时，先改 skill（外部仓库）再回来实现。
- skill 的 scope 只有界面：播放、扫描、网络、存储、账户等逻辑仍按
  [architecture.md](architecture.md) 与本仓库规范实现，不得因"skill 没写"而改行为。

## 3. 许可与 AGPL 边界

| 对象 | 许可证 | 在本仓库的处理 |
|---|---|---|
| ArchoeraMusic-UI（现行版本） | **MIT**（© 2026 Archoera && BetaStudio2） | 可复制 / 修改 / 合并，保留声明；与本仓库 AGPL 兼容 |
| ArchoeraMusic-UI（早期版本） | **AGPL-3.0-or-later**（见其 `NOTICE.md` 的 license history） | 钉住旧 commit 时按该 commit 的 `LICENSE` 执行 |
| 本仓库 ArchoeraMusic | **AGPL-3.0-or-later** | 整体分发义务不变 |

执行规则：

1. **MIT 兼容，可以复制**：MIT 允许使用、复制、修改、合并、发布、再许可与分发。把 skill
   的规格文本、token 表、预览 HTML / CSS / JS / 图片引入本仓库（含 `app/`）都是允许的；
   唯一硬性条件是**保留其版权与许可声明**。本仓库整体仍按 AGPL-3.0-or-later 分发，
   MIT → AGPL 方向兼容，不构成冲突。
2. **仅参考不产生署名义务**：只读规格、在 Flutter 里独立实现配色 / 尺寸 / 布局，未复制
   受版权保护的表达时，不需要履行 MIT 的声明义务；在 [acknowledgements.md](acknowledgements.md)
   致谢是项目惯例，不是许可前提。
3. **登记是溯源惯例，不是许可条件**：实际 vendored 了 skill 的文件时，建议在对应模块
   `THIRD-PARTY-LICENSES.md` 登记来源与版本，便于审计和升级；漏登记属流程问题，
   不构成 MIT 违规（声明本身仍须随副本保留）。
4. **反向不"洗许可"**：把本仓库 AGPL 代码放进 ArchoeraMusic-UI（MIT）不会让这些代码变成
   MIT；含 AGPL 代码的分发整体仍须满足 AGPL（提供对应源码等）。要保持该仓库纯 MIT，
   就不要混入本仓库源码。版权持有者对自己拥有的代码可以另行授权，但贡献者代码按
   [贡献者授权](licensing.md#21-贡献者授权contributor-license-grant)仅授予 AGPL 再许可。
5. **不扩权**：skill 的 MIT 只覆盖该仓库自身的内容，不改变 ArchoeraMusic 应用源码、
   项目名与 logo、EtaMark、封面美术、字体文件的许可状态——这些仍按各自条款。
6. **资源按各自许可**：MiSans 不得单独再分发字体文件；图标继续走本仓库 `EtaIcons` 流程；
   封面 / logo / 品牌标识不在 skill 授权范围。`assets/preview-*.png` 是 skill 自身 HTML 的
   渲染图（MIT，可用于文档 / 测试），但不要当作本应用的官方截图对外宣传——这是事实与
   品牌问题，不是许可禁令。
7. **外部仓库改动**：需要修改 skill 时去其仓库按当地规范提交；本仓库 PR 不夹带外部仓库改动。

## 4. 自查清单（不是许可审查）

- [ ] 设计依据指向 skill 的具体 commit / tag，而不是"参照现有页面"或某张截图。
- [ ] 颜色、圆角、间距、壳层尺寸、播放器布局、动效时长取自 skill；偏离项有书面理由。
- [ ] 若复制了 skill 的文本 / 代码 / 资源，副本中保留了 MIT 版权与许可声明。
- [ ] 反向复用时没有把 AGPL 代码以 MIT 名义分发（含 AGPL 的分发按 AGPL 合规）。
- [ ] 字体、图标、封面、品牌标识的使用符合各自许可。
- [ ] 行为逻辑（播放 / 扫描 / 网络 / 存储 / 账户）未被"视觉改版"顺手改动。

> 以上只有第 3、4、5 项涉及许可义务；其余是设计流程与架构一致性检查。

## 5. 与历史文档的关系

- [architecture.md](architecture.md) §10.7「UI 适配（Web/Vue → Flutter）」是 2026-08 的
  **历史迁移记录**，保留用于追溯实现沿革与行为映射，**不再是新 UI 的设计原型**。
- [style-registries.md](style-registries.md) 描述的是「契约 + 注册表 + 独立模块」的**接入机制**，
  机制照旧；每个样式模块内的具体视觉参数以 skill 为准。
- 本文件与 `CONTRIBUTING.md` §4 #13 同步修订；只改一处视为未完成。
