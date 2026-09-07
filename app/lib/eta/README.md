# eta 图标体系食用说明

> 面向本仓库二次开发者的 **eta（η）图标/品牌字形体系**开发文档。
> 一句话结论：**界面里要用图标，一律写 `EtaIcons.xxx`（或品牌标识 `EtaMark.brand`），禁止再用 Material `Icons.*`。**

## 目录

1. [体系是什么](#1-体系是什么)
2. [怎么引用图标](#2-怎么引用图标)
3. [实心还是描边：裸名 vs Outline](#3-实心还是描边裸名-vs-outline)
4. [品牌标识（EtaMark）怎么用](#4-品牌标识etamark怎么用)
5. [命名怎么来的（mapping 约定）](#5-命名怎么来的mapping-约定)
6. [没有想要的图标怎么办（新增字形）](#6-没有想要的图标怎么办新增字形)
7. [重新生成字体/常量的流程](#7-重新生成字体常量的流程)
8. [代码审查/迁移清单](#8-代码审查迁移清单)
9. [许可与致谢义务](#9-许可与致谢义务)

---

## 1. 体系是什么

自建**两套字体** + **两层引用常量**，全部收在 `app/` 包内：

| 层次 | 内容 | 位置 |
| --- | --- | --- |
| 图标常量 | `EtaIcons.*`（213 个，含实心/描边） | `app/lib/eta/icon/eta_icons.dart` |
| 品牌常量 | `EtaMark.brand`（均衡器频谱标识） | `app/lib/eta/mark/eta_mark.dart` |
| 图标字体 | `EtaIcons`（family）→ `EtaIcons.ttf` | `app/assets/fonts/EtaIcons.ttf` |
| 品牌字体 | `EtaMark`（family）→ `EtaMark.ttf` | `app/assets/fonts/EtaMark.ttf` |
| 图标源/注册表 | 定稿 SVG + material 映射 | `app/eta-tools/eta_icons/` |
| 品牌源图 | `logo-trim.png` → 黑白矢量 | `app/eta-tools/eta_mark/` |

- 两字体已在 `app/pubspec.yaml` 注册（`family: EtaIcons` / `family: EtaMark`）。
- `eta_icons.dart` / `eta_mark.dart` 是 **AUTO-GENERATED** 文件：**不要手改**，
  由 `app/eta-tools/` 下脚本重新生成。

## 2. 怎么引用图标

```dart
import 'package:archoera_music/eta/icon/eta_icons.dart';

Icon(EtaIcons.play, size: 24, color: scheme.primary);
IconButton(icon: const Icon(EtaIcons.heart), onPressed: ...);
```

- 无需（也不应）import `package:flutter/material.dart` 里的 `Icons`。
- 图标字体与全局主题字体独立：`IconData` 自带 `fontFamily: 'EtaIcons'`，
  常规 `Icon(...)` / `IconButton(...)` 直接可用，不受主题 `fontFamily` 覆盖影响。

## 3. 实心还是描边：裸名 vs Outline

同一视觉概念在字体里有两个**独立 codepoint**：

| 引用 | 视觉 | 对应旧 Material 语义 |
| --- | --- | --- |
| `EtaIcons.play` | 实心（filled） | `Icons.play_arrow`（无后缀） |
| `EtaIcons.playOutline` | 描边（regular） | `Icons.play_arrow_outlined` |

- **默认**用哪个？沿用 Material 语义：无后缀/`_filled` → 裸名实心；`_outlined/_border` → `xOutline`。
- 需要「实心/描边成对切换」（如喜欢与否、选中态）时**两个都引用**：

```dart
// 喜欢 = 实心心；未喜欢 = 描边心
Icon(liked ? EtaIcons.heart : EtaIcons.heartOutline);
```

> 旧代码里 `favorite` ↔ `favorite_border` 的双图标分支，重构后分别对应
> `heart` ↔ `heartOutline`，切换逻辑**原样保留**即可。

## 4. 品牌标识（EtaMark）怎么用

品牌标识（均衡器频谱）走**独立字体族 `EtaMark`**，与通用图标解耦，不受
泛化图标替换影响；现仅 `AppLogo` 使用。

```dart
import 'package:archoera_music/eta/mark/eta_mark.dart';

Icon(EtaMark.brand, size: 18, color: scheme.onPrimaryContainer);
```

## 5. 命名怎么来的（mapping 约定）

定稿映射存于 `app/eta-tools/eta_icons/src/eta_icons.csv` 与 `registry.json`：

- **glyph 概念名** = mingcute 图标名去尾序数与风格后缀：`refresh_2 → refresh`、
  `user_1 → user`；同概念多款（`magic_2/magic_3`）才保留序数。
- **裸名 = 实心**，**裸名 + `Outline` = 描边**（依据源 Material 名的 `_outlined/_border` 判定）。
- 外部补入图标（Tabler，`added/`，如 `abc`、`highQuality`）仅有描边，无实心孪生。

> 想确认某个 `EtaIcons.xxx` 是否存在、或「我该写 `xx` 还是 `xxOutline`」：
> 在 `app/lib/eta/icon/eta_icons.dart` 搜名字，或查 `eta-tools/eta_icons/src/eta_icons.csv` 的
> `material → eta_const` 行。

## 6. 没有想要的图标怎么办（新增字形）

**尽量复用已有字形**（213 个覆盖了全部旧 Material 引用 + weather 全集）。若确需新增：

1. 拿到目标 SVG（建议 24×24、单色描边/实心风格与 mingcute 一致）。
2. 放对归档目录（描边 → `app/eta-tools/eta_icons/source/regular/<glyph>.svg`；
   实心 → `.../filled/<glyph>.svg`；外部补入 → `.../added/<glyph>.svg`）。
3. 按 §7 重跑校验 + 字体 + 常量生成，得到 `EtaIcons.<新名>`。
4. 若将来 Material 语义图标增加，先补 `mapping.csv` 再走生成（见 §7 注）。

> 动画类（loading/downloading 的转圈等）**不做字形**：循环动画一律用
> Flutter 原生 `AnimationController`/`CircularProgressIndicator` 复刻，参见
> 规划文档对「动态字形」的处理约定。

## 7. 重新生成字体/常量的流程

前置：`app/eta-tools/` 下需 node（一次性 `npm install`）与 python3。

```bash
# 0) 校验归档完整（新增字形后必跑）
python3 app/eta-tools/eta_icons/5_copy_sources.py

# 1) 描边 SVG 扩成填充轮廓 → app/eta-tools/eta_icons/svg/
node app/eta-tools/eta_icons/1_prepare_svg.mjs

# 2) 打成字体 → app/eta-tools/eta_icons/dist/EtaIcons.ttf
node app/eta-tools/eta_icons/2_build_font.mjs
cp app/eta-tools/eta_icons/dist/EtaIcons.ttf app/assets/fonts/EtaIcons.ttf

# 3) 重新生成 Dart 常量 → app/lib/eta/icon/eta_icons.dart
node app/eta-tools/eta_icons/3_gen_dart.mjs
```

> 注册表（material 映射）日常**无需重跑**，已随库入库；
> 只有当你改 mapping/语义映射时才需 `python3 src/0_gen_registry.py`（需 mingcute
> 原素材，见下）。字体生成参数已锁 `fontHeight:1000 / ascent:1000 / descent:0`
> （svgtofont 默认会产出畸形字体），勿改动。

品牌标识 EtaMark 独立生成（改 logo 源图时）：

```bash
node app/eta-tools/eta_mark/1_prepare.mjs   # logo-trim.png → brand.svg
node app/eta-tools/eta_mark/2_build_font.mjs
cp app/eta-tools/eta_mark/dist/EtaMark.ttf app/assets/fonts/EtaMark.ttf
```

> 注：`Icon化/` 全量素材已作本地参考删除且 gitignore；`0_gen_registry.py`
> 依赖的 mingcute 原 mapping 若缺失则不可用——新增字形以 §6「直接放 source」为推荐路径。

## 8. 代码审查/迁移清单

新增/改 UI 时对照：

- [ ] 没出现新的 `Icons.`（裸 Material）；有则改 `EtaIcons.*`
- [ ] 实心/描边语义与 Material 原写法一致（原无后缀 → 裸名；原 `_outlined` → `xOutline`）
- [ ] 成对切换（like/选中/展开）两个常量都引用，视觉分支保留
- [ ] 品牌 Logo 位置用 `EtaMark.brand`，不挪用通用 `EtaIcons.soundLine` 等
- [ ] 新图标已进 `source/` 与注册表，常量是**生成**的（勿手写）

全库迁移脚本：`python3 app/eta-tools/eta_icons/4_replace_icons.py`（项目已
EtaIcons 化时幂等跳过；历史 Material 迁移时使用）。

## 9. 许可与致谢义务

- 图标字形源：**MingCute Icons**（Apache-2.0）、缺口补入 **Tabler Icons**（MIT）。
- 对源图标做了**改作**（描边 SVG → 描边转轮廓 → 重打包字体），属许可允许的衍生改作，
  但需保留来源与修改声明 —— 已在仓库根 `README.md`「第三方声明 / 特别鸣谢」登记。
- 详细逐项见 `app/eta-tools/eta_icons/source/LICENSE-*`；品牌标识 EtaMark 为项目自建字形。
