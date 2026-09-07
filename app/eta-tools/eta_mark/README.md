# EtaMark — 品牌标识独立字体族

> **食用说明（开发向）见 [`app/lib/eta/README.md`](../../lib/eta/README.md)**：
> 品牌标识的引用写法与新增字形约定都收敛在该文档。

承载「均衡器频谱」品牌标识（源：`source/logo-trim.png` 白形透明底 → potrace
矢量化 → svgtofont 打成**独立字体族 EtaMark**），供 AppLogo 等品牌位置使用，
与通用图标 `EtaIcons`（mingcute）解耦，品牌字形不被泛化替换改观感。

## 落点

| 产物 | 路径 |
| --- | --- |
| 字体 | `app/assets/fonts/EtaMark.ttf`（family=EtaMark） |
| Dart 常量 | `app/lib/eta/mark/eta_mark.dart` → `EtaMark.brand` |
| 源图 | `app/eta-tools/eta_mark/source/logo-trim.png` |
| 中间/产物 | `svg/` `dist/`（gitignore，可再生） |

## 重新生成

```bash
cd app/eta-tools/eta_mark && npm install        # 一次性装 potrace / svgpath / svgtofont
node 1_prepare.mjs                     # 源图→ 24 单位 brand.svg
node 2_build_font.mjs                  # → dist/EtaMark.ttf，拷到 app/assets/fonts/
```

> 字体生成参数与 EtaIcons 保持一致：`fontHeight:1000 / ascent:1000 / descent:0`，
> 否则 svgtofont 默认 unitsPerEm=24 会产出畸形字体。
