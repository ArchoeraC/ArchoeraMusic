# ArchoeraMusic 宣传页（GitHub Pages）

纯静态产品页：开屏动效按应用源码复刻，随后是电影感首屏、滚动叙事、能力清单、
引擎管线、样式注册表、开屏演示、下载与文档。

**运行时不依赖 Node、CDN 或任何服务端**：只有 HTML / CSS / 原生 JS、本地字体与图片。
`site/` 目录原样上传即可，GitHub Pages 只负责静态分发。

## 本地预览

```bash
# 仓库根目录
python3 -m http.server 8083 -d site
# 打开 http://127.0.0.1:8083/
```

> 直接双击 `index.html` 也能看，但字体/JS 走 `file://` 时行为因浏览器而异，建议起一个本地服务。

## 目录

```
site/
├── index.html              # 单页
├── assets/
│   ├── css/site.css        # 色板、版式、开屏动效、滚动叙事（曲线/时长都在这）
│   ├── js/site.js          # 开屏、滚动显现、导航高亮、叙事切换、跑马灯
│   ├── fonts/              # Manrope / EtaMark / EtaIcons（取自 app/assets/fonts）
│   ├── img/                # logo、真实界面截图与三种播放页布局
│   └── licenses/           # 字体许可原文
└── README.md
```

## 页面结构

| 区块 | 内容 |
| --- | --- |
| `#splash` | 整屏开屏，1.9s + 550ms 淡出；点击/按键可跳过 |
| Hero | 大字号主张、下载/开屏/源码入口、产品窗口与浮动参数标签 |
| Ticker | 解码格式与音源服务的无缝跑马灯 |
| 立场 | 「不塞广告 / 不做遥测 / 不要求管理员权限」+ 4 项规格数字 |
| Cinema | 全幅沉浸式播放页：图片随滚动轻微缩放，文案覆盖在封面与歌词上 |
| `#product` | 滚动叙事：左侧文案滚动、右侧视觉固定并切换三种视图（真实截图 + 布局切换） |
| `#features` | 9 项能力清单（发丝分割线 + 序号） |
| `#engine` | 输入 → 解码 → DSP → 输出管线、宽幅频谱、进程与语言分工 |
| `#styles` | 8 个样式域与真实偏好 id |
| `#gallery` | 横向界面画廊：原生滚动 + 卡片吸附 + 箭头翻页，计数/进度来自真实滚动位置，可点开大图 |
| `#splash-demo` | 可重播的开屏舞台、Stable/EraAudio、0.5× 慢放、参数时间线 |
| `#download` | 三端包格式、Releases 入口、签名校验说明 |
| `#docs` | 文档索引 |
| Finale / Footer | 结尾 CTA、项目链接、许可 |

滚动显现、导航高亮、进度条、移动菜单、跑马灯复制、产品视图切换都在 `site.js`；
所有动画只改 `opacity` / `transform`，并遵守 `prefers-reduced-motion`。

## 真实界面截图

页面里的应用画面全部来自**应用本体的实际渲染**，不是 CSS 拼出来的效果图：

| 文件 | 对应界面 |
| --- | --- |
| `assets/img/home.webp` | 发现页：每日推荐、推荐歌单、播放条 |
| `assets/img/library.webp` | 本地曲库：曲目列表、扫描统计、本地搜索 |
| `assets/img/player.webp` | 全屏播放页（fullscreen 布局）：封面、逐字歌词、频谱 |
| `assets/img/player-default.webp` | 默认播放页（default 布局） |
| `assets/img/player-vutron.webp` | Vutron 布局 |
| `assets/img/settings.webp` | 外观设置：主题色 / 背景风格 / 布局 |
| `assets/img/layout-*.webp` | 三种播放页布局的缩略图（产品叙事区可切换） |
| `assets/img/home-og.png` | 社交预览图（Open Graph） |

原图以 1600×1000 的逻辑窗口渲染（HiDPI 下约 2000×1215），再转成 WebP 以控制体积。
换截图时保持同一窗口尺寸与主题，避免同一页里画面比例和观感不一致。

## URL 参数（预览 / 截图用）

| 参数 | 作用 |
| --- | --- |
| `?nosplash` | 跳过整屏开屏，直接看内容 |
| `?preview` | 跳过开屏与入场/滚动动画，直接呈现所有终态（截图、观感检查） |
| `?static` | 开屏停在动画终态，不自动淡出 |
| `?engine=eraudio` | 开屏展示「Powered by EraSync」品牌行（等同在演示区切到 EraAudio） |
| `?stage=end` | 页内演示区直接呈现终态 |

演示区的 `Stable / EraAudio` 选择会写入 `localStorage`，之后重播整屏开屏也会沿用。

## 开屏动效的来源

页面上的开屏不是「看着像」，参数逐项来自应用源码：

| 页面实现 | 应用源码 | 参数 |
| --- | --- | --- |
| `.splash-logo` | `app/lib/widgets/common/splash_screen/splash_screen_widgets.dart` | 72px 圆角方块（radius 21.6）、0–500ms 上移 16% + 渐亮、`easeOutExpo` |
| `.splash-brand .char` | 同上 `_StaggeredText` / `_StaggeredChar` | 34px/700 Manrope、逐字延迟 38ms、单字 420ms、上移 18px、`easeOutCubic` |
| `.splash-glow` | 同上 `_buildGlow` | 主色 `#D0D3DA`，Alignment(-0.7, -0.8)，radius 1.1，0–550ms 淡入 |
| `.splash-footer` | 同上 `_buildFooter` | bottom 32、350–850ms、终态 0.4 透明度 |
| `.splash-engine` | 同上 `_buildEngineBadge` | 500–950ms、终态 0.8、20px `EtaMark.erasync` |
| `#splash.is-dismissing` | `app/lib/app/bootstrap.dart` | 停留 1.9s 后 550ms 淡出：透明度 1→0、scale 1→0.98、上移 3%、`easeInCubic` |

Flutter 曲线到 CSS 的映射：`easeOutExpo → cubic-bezier(.16,1,.3,1)`、
`easeOutCubic → cubic-bezier(.215,.61,.355,1)`、`easeInCubic → cubic-bezier(.55,.055,.675,.19)`。
系统开启「减少动态效果」时，入场压到 1ms、开屏直接呈现终态并跳过淡出（对应应用的性能模式）。

改源码里的开屏参数时，同步改 `site/assets/css/site.css` 中对应的 `--t` 倍率计算与关键帧。

## 部署

`.github/workflows/pages.yml` 在 `main` 上 `site/**` 变更时构建并发布。

首次启用需要在仓库 **Settings → Pages → Build and deployment → Source** 选择
**GitHub Actions**；之后推送即自动发布到 `https://betastudio2.github.io/ArchoeraMusic/`。

## 许可与素材

- 页面代码随仓库以 **AGPL-3.0-or-later** 发布。
- `Manrope.ttf`：SIL OFL 1.1，见 `assets/licenses/Manrope-OFL-1.1.txt`。
- `EtaMark.ttf` / `EtaIcons.ttf`：项目自建字体，字形来源与许可见
  `app/eta-tools/eta_mark/`、`assets/licenses/EtaIcons-LICENSES.txt`（MingCute Apache-2.0 / Tabler MIT 等）。
- 截图取自应用本体，画面中的封面与歌单信息版权归各自权利人所有，仅作界面展示。
