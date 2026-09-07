# eta_icons — ArchoeraMusic 自建图标字体

> **食用说明（开发向）见 [`app/lib/eta/README.md`](../../lib/eta/README.md)**：
> 引用写法、实心/描边命名、新增字形、重新生成、审查清单全在这里。
> 本文件只讲**工具链本身**的产物与复现步骤。

项目内所有图标引用统一归一化为 `EtaIcons.*`（见 `app/lib/eta/icon/eta_icons.dart`），
不再直接引用 Material `Icons.*`。字形源为 **mingcute icons**（Apache-2.0，见
`source/LICENSE-mingcute.txt`），缺口由 **Tabler Icons**（MIT，`added/`）补齐，
`line-md`（MIT）仅作播放器动画离线参考，本工具链不消费它。

## 产物与落点

| 产物 | 路径 | 说明 |
| --- | --- | --- |
| 字体（ttf） | `app/assets/fonts/EtaIcons.ttf` | 单字体族单文件；描边/实心以不同 codepoint 区段共存 |
| Dart 常量 | `app/lib/eta/icon/eta_icons.dart` | `EtaIcons.x`（实心）/ `EtaIcons.xOutline`（描边） |
| 注册表 | `src/registry.json` + `src/eta_icons.csv` | material→glyph→const 权威映射 |
| 定稿源 SVG | `source/{regular,filled,added}/` | 入库存档，字体可从纯仓库重生成 |

## 命名约定

- **裸名 = 实心（Material 无后缀视觉）**，如 `EtaIcons.play`；
- **`xOutline` = 描边（Material `_outlined` 视觉）**，如 `EtaIcons.playOutline`；
- glyph 概念名自动去尾序数（`refresh_2 → refresh`），冲突才保留（`magic_2/magic_3`）；
- 外部补入（Tabler）仅有描边，无 `xFilled` 孪生。

## 重新生成（一次性脚本，开发机用）

前置：源全集（`Icon化/`）已作为本地参考删除且不入库；**入库源即本目录
`source/`（只含项目使用字形的定稿 SVG）**，字体可从纯仓库直接重生成。

```bash
cd app/eta-tools/eta_icons && npm install          # 一次性装 paperjs-offset / svgtofont
# 1. 校验 source/ 覆盖 registry 全部字形（新增字形需先在 source/{regular,filled,added} 补 SVG）
python3 5_copy_sources.py
# 2. 重新扫描 app 使用 + 生成注册表（material→const 映射）
python3 src/0_gen_registry.py
# 3. 描边 SVG 扩成填充轮廓（paperjs），产 app/eta-tools/eta_icons/svg/
npm run step1
# 4. 打成字体，产 app/eta-tools/eta_icons/dist/EtaIcons.{ttf,woff2}，手动拷贝到 app/assets/fonts/
npm run step2
# 5. 重新生成 Dart 常量文件
node 3_gen_dart.mjs
# 6. 全局替换 Icons.* → EtaIcons.*（app/lib 内；项目已 EtaIcons 化时脚本幂等跳过）
python3 4_replace_icons.py
```

> 说明：svgtofont 默认产 `unitsPerEm=24` 的畸形字体，脚本已显式指定
> `fontHeight:1000 / ascent:1000 / descent:0`，务必保留。

## 许可注意

- 随 app 分发需遵守各自许可：mingcute Apache-2.0、Tabler MIT、line-md MIT；
  源 SVG 与字体二进制的声明见本目录 `source/LICENSE-*`。
- 字形源中 `regular/` 是描边式（`fill=none`+`stroke`），字体字形为「填充」渲染，
  因此本工具用 `paperjs-offset` 做描边扩轮廓（与 mingcute 官方字体生成同法）。
