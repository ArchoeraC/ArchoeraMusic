# 运行时资源优化（Runtime Resource Optimization）

> 状态：**规划中（2026-09-16 立项，未实施）**
> 主线：**GPU / 渲染开销**（当前与上游 SPlayer-Next 差距最大，优先处理）；
> 副线：**页面与模块的按需加载 / 卸载**（内存与启动）。
> 定位：在 [player-render-optimization.md](player-render-optimization.md)（播放页三引擎）
> 之上，补两块此前没有系统化的工作：① **跨框架渲染机制调研**（Qt / Chromium / WebRender /
> Impeller），② **运行时生命周期**（页面 / 模块 / 缓存）。播放页细节仍以专项文档为准。

---

## 0. TL;DR

- 我们比上游「重」的根因**不是 Flutter 本身**，而是**效果预算与生命周期**：
  上游水纹是 **0.55 尺度的 WebGL canvas**、**展开才挂载、收起即卸载**；我们是
  **全分辨率逐像素 / CPU 顶点场**、**常驻**。
- 跨框架（Chromium `cc`、Qt Quick Scene Graph、WebRender、Impeller）殊途同归的四个杠杆：
  **① 图层缓存（FBO / layer）② 只更新损伤区（partial raster）③ 降分辨率/降采样
  ④ 不可见即停（occlusion + 生命周期）**。本方案全部对齐这四点。
- 背景（最大头）的目标形态：**静态层缓存一次（模糊封面 + 压暗）+ 动态层只在「水纹损伤区」
  以低分辨率绘制**；回退阶梯保证软渲染/老 iGPU 可用。
- 生命周期：`go_router` 已做「懒建分支 + `Offstage` + `TickerMode`」，缺的是**卸载**（分支状态永驻）
  与**模块按需**（downloader 启动常驻，见 [module-on-demand-load-plan.md](module-on-demand-load-plan.md)）。

---

## 1. 背景与目标

### 1.1 现象（用户 2026-09-16）
- 我们的**软件渲染要求**与**资源开销**相对上游 SPlayer-Next（Electron / Chromium）**高很多**。
- GPU 是其中最严重的一项：全屏播放页在集显（iGPU）上掉帧。

### 1.2 目标（可验收）
1. **iGPU 优先**：Intel UHD/Iris、AMD Vega、Apple 集显上全屏播放页达帧预算；
   软渲染（llvmpipe/SwiftShader）不崩、可降级。
2. **不靠独显**：不以「上独显才流畅」为前提。
3. **常量级常驻**：内存峰值与歌长/列表长度/分支数量弱相关，可回收。
4. **不在渲染主路径引入新进程**：遵守 `AGENTS.md`（不新增进程承载图形/桥接）。

---

## 2. 现状与差距对照

| 维度 | 上游 SPlayer-Next（Electron） | 我们（Flutter） | 差距性质 |
|---|---|---|---|
| 水纹背景 | `BackgroundRipple.vue`：**0.55 渲染尺度** WebGL/WebGPU canvas + CSS `blur(10px)` | `ripple_background.dart`：**全分辨率 CPU 顶点场**（≤160×90 顶点 × 48 涟漪，UI 线程） | 像素量 ×3.3、线程、算法 |
| 背景生命周期 | 展开后**延迟 500ms 挂载**、收起 **500ms 卸载**（`PlayerBackground.vue:15-43`） | 路由 push 即建、pop 才销毁 | 常驻/首帧成本 |
| 图层结构 | blur/ripple **共用** `.bg-blur-wrap` + 单个 `::after` 压暗 | 多遍全屏叠层（gradient + 模糊 + 折射 + 压暗） | overdraw |
| 文本 | Chromium 字形栅格缓存 + 合成层 | v7 每帧 `TextPainter.layout()`（P1 已部分解决） | UI 线程 |
| 列表/分支 | Chromium tile + occlusion culling，标签可丢弃 | `go_router` 懒建分支 + `Offstage` + `TickerMode`；**访问过即永驻** | 缺「卸载」 |
| 模块 | 渲染/媒体多进程、按需 | downloader `bootstrap.dart:46` **启动即常驻** | 缺「按需」 |

> 说明：Electron/Chromium 自身内存并不小；真正可比的是**单个效果的开销预算**与**生命周期纪律**，
> 框架只是提供了成熟的合成器机制。我们的思路是「**借用机制，不照搬架构**」。

---

## 3. 跨框架机制调研（提炼可迁移项）

### 3.1 Chromium / Electron（`cc` 合成器）

- **图层化（layerization）**：动画/滚动元素提升为独立合成层，未变图层不重光栅（`will-change`）。
- **分块光栅（tiling）**：把大层切成固定像素块（256/512），只光栅/上传受影响的块。
- **部分重绘（partial raster / damage）**：只重绘**损伤区**；静态内容不重复计算。
- **遮挡裁剪（occlusion culling）**：被不透明层完全覆盖的内容直接丢弃绘制。
- **绘制批处理（quad batching）**：相同材质/纹理的 quad 合并，减少 draw call / 状态切换。
- **可丢弃内存（discardable memory）**：内存压力下抛弃可再生资源（解码图、缓存纹理）。
- **后台节流（background throttling）**：不可见标签降频/停渲染。

### 3.2 Qt Quick（Scene Graph + RHI）

Qt 的文档把与我们的问题高度重合的坑写得很直白，可直接对照：

- **保留式场景图**：渲染前已知全部图元 → **批处理**、可视顺序无关的**重排**、**丢弃被遮挡图元**
  （三者正是 `cc` 的 batching / reorder / occlusion）。
- **`QSGNode::preprocess`**：按当前 scale 决定 **LOD**、只更新**纹理局部**——即「按需精度」。
- **`QSGLayer` / `ShaderEffectSource`**：把子树预渲到 FBO 后复用；文档同时警告
  `ShaderEffectSource` 的**额外离屏代价很贵**，`QQuickPaintedItem` 是**两级**（先光栅后贴），
  能直接上场景图就别用它。
- **裁剪不是优化**：`clip` 会**阻止重排、破坏批处理**，在 delegate 里尤其糟。
  （对照：Flutter 的 `ClipRect`/`ClipRRect`/`saveLayer` 同样打断合批；`saveLayer` 更是整层离屏。）
- **遮挡与不可见**：被不透明元素完全盖住的应 `visible=false`；不可见但仍需存在的元素也应
  `visible=false` 以免绘制（但动画/绑定仍在跑——这点和 Flutter 的 `Visibility`/`TickerMode` 一致）。
- **不透明优于半透明**：半透明要混合，破坏不透明优化（一个透明像素即整图按透明处理）。
- **`ShaderEffect`**：逐像素运行，低端机**限制指令数**；大面积时是填充率杀手。
- **图片**：`Image.asynchronous`、**`sourceSize` 按显示尺寸解码**（对照 `CoverImage` 的
  `cacheWidth/cacheHeight`）；避免无谓 `smooth`。
- **生命周期**：`Loader` 懒加载，**`destroy()` 释放**未用元素；**粒子系统不可见即停**。
- **渲染循环**：`threaded`（GUI/render 线程分离，vsync 驱动动画）——Flutter/Impeller 已内建同构分离。

### 3.3 WebRender（Servo / Firefox）

- **保留式显示列表（display list）** + **picture caching**：把「内容切片」缓存为纹理，
  仅滚动/变换时不重录。
- **clip / scroll 节点**与**内容无关的合成**；GPU 批次 + **纹理图集（atlas）**。

### 3.4 Flutter / Impeller 与 Skia（我们的运行层）

- **Impeller**：单 RenderPass 合并、tile memory、绘制批处理、clip coverage；
  但**逐像素着色器成本不变**——`FragmentProgram` 仍是每像素执行。
- **`RepaintBoundary`**：Flutter 的「图层缓存」入口（配合 raster cache）。稳定内容应包起来，
  避免每帧全量重光栅；但**不能滥用**（层过多 → 合成/显存上升，且 Impeller 层缓存有上限）。
- **`ImageFilter.shader` 仅 Impeller 可用**（`painting.dart:4461`，否则 `UnsupportedError`），
  不适合作为**跨三端**方案的主路径。
- **Skia 可借鉴**：`Canvas.drawAtlas`/`drawRawAtlas`（批量贴图）、`Paragraph` 缓存。
- **`BackdropFilter` / `ImageFiltered` / `saveLayer`** = Qt 的 `ShaderEffectSource`：
  都是**多一遍离屏**，全屏使用是红线级开销（现有 render 文档 §3.2.6 已述）。

### 3.5 可迁移机制清单

| 机制 | 主要出处 | 我们对应的落点 |
|---|---|---|
| 图层缓存 / FBO 复用 | Qt `QSGLayer`、`cc` layers | 背景**静态层**、播放条、侧边栏包 `RepaintBoundary` |
| 只更新损伤区 | `cc` partial raster、Qt preprocess | 水纹**动态层**只画活动涟漪 |
| 降分辨率 / LOD | `cc` tiling、Qt preprocess | 动态层低分辨率离屏、静态层 1/2~1/4 预烘焙 |
| 遮挡裁剪 / 不可见即停 | Qt `visible=false`、`cc` occlusion | `Offstage`/`Visibility` + `TickerMode`（已有，扩展） |
| 批处理 / 图集 | Qt batching、Skia `drawAtlas`、WebRender atlas | 频谱单 Path（已 P3）→ 评估 `drawAtlas`；歌词字形缓存 |
| 裁剪的代价 | Qt「clip 不是优化」 | 减少 `Clip*`/`saveLayer`，尤其列表 delegate |
| 不透明优先 | Qt | 避免无谓半透明/模糊叠层 |
| 生命周期 / Loader | Qt Loader+destroy、`cc` discardable | 页面分支卸载、模块注册表、图片缓存上限 |
| 后台节流 | Chromium background throttling | `power_saver.dart` + `FrameGovernor`（连 ticker 一起停） |

---

## 4. 我们的方案

### 4.1 GPU 主线 — 背景（最高优先）

**目标形态：静态/动态分离 + 损伤区绘制 + 降分辨率。**

1. **静态层（缓存一次）**：模糊封面 + 压暗（+ 交叉淡入的双缓冲）只在**切歌时重做**，
   存为稳定 `ui.Image` / `RepaintBoundary` 层，正常帧不重算。对应 Qt `QSGLayer` / `cc` 静态 tile。
2. **动态层（只画脏区）**：每个活动涟漪只在其**波带邻域**内产生折射/高光；不在波带内的像素
   与静态层一致，可跳过。对应 Qt `preprocess`（只更新局部）与 `cc` partial raster。
3. **降分辨率**：动态层在 **1/2~1/4** 离屏分辨率计算再放大；静态层预烘焙同样降采样。
   对应 `cc` tiling 与 Qt LOD，也是原 render 文档 §4.1 P2b 的思路。
4. **收敛 pass**：理想压到 **2 pass**（静态层贴图；动态层脏区），不再 gradient+blur+折射+压暗四遍。

**动态层的实现选型（待实测，见 §8）**：
- A. **局部几何**：按涟漪波带生成环带/局部网格，用 `FragmentProgram` 或 `drawVertices` 绘制。
- B. **低分辨率场纹理**：先在低分辨率算出折射位移场（CPU 小网格或小 pass），
  全屏只做「采样位移场 + 采样封面」的廉价贴图。
- C. **低分辨率离屏 + 放大**：整层以 `Picture.toImageSync(小尺寸)` 渲染再 `drawImageRect` 放大
  （真实降低填充；需测每帧纹理分配成本）。

**回退阶梯**（务必保留）：`FragmentProgram` 不可用 / 软件渲染 / 老 iGPU →
降采样倍率 → 只画**活动**且**波带命中**的局部 → 最终退回现有 CPU 网格 `_RipplePainter`。
不变量（随机序列、生命周期、速度、间距、交叉淡入）与上游一致。

### 4.2 GPU 纪律 — 图层 / overdraw / 裁剪

- **稳定层**：背景静态层、顶栏、侧边栏、底部播放条、歌词区、频谱各自 `RepaintBoundary`，
  把「每帧变化的层」与「几乎不变的层」隔离（避免全屏重光栅）。
- **去离屏 pass**：清理无谓 `ClipRRect`/`ClipRect`/`saveLayer`/`BackdropFilter`；
  列表 delegate 内**禁止**裁剪（Qt：clip 破坏批处理）。已有 `ShaderMask` 渐隐并入画笔（P3）为先例。
- **不透明优先 / 遮挡即不画**：被不透明层盖住或不可见的内容 `Visibility(visible:false)` 或
  `Offstage`，不要用「透明」硬画。
- **图片预算**：沿用 `CoverImage` 的按显示尺寸解码；补 `PaintingBinding.imageCache` 上限
  与「路由退出 evict」。

### 4.3 文本 / 几何批处理

- **歌词**：延续 P1（Paragraph 缓存 + 去 `saveLayer`）；P4（逐字符图集）对照 Qt 的
  distance-field 字形缓存评估，仅在实测仍为瓶颈时做。
- **频谱**：已在 P3 合为单 `Path`；`drawAtlas` 作为进一步手段（大量同形精灵时最优）。

### 4.4 运行时生命周期 — 页面 / 模块

- **页面（分支）**：
  - 现状：`router.dart` 的 `StatefulShellRoute.indexedStack` 已「**首次访问才创建分支**」，
    go_router 用 `Offstage + TickerMode` 包裹非活动分支（`_IndexedStackedRouteBranchContainer`），
    即**已不绘制、已停 ticker**。
  - 缺口：**访问过的分支子树与状态永驻**。补：长时间未用 / 内存压力时**卸载重建**
    （可选保留状态：轻量状态经 `PageStorage` / provider，重对象直接释放）。
  - 非活动分支额外释放：大 `ui.Image`（封面）、长列表缓存、订阅。
- **模块**：落地 [module-on-demand-load-plan.md](module-on-demand-load-plan.md)：
  先解除 `bootstrap.dart:46` 的 downloader 启动常驻，再上注册表引用计数 + 用后释放。
- **播放页**：收起/退出即释放（现状 `dispose` 已释放 shader/纹理）；可学上游**展开延迟挂载**，
  避免首帧同时构建背景 + 歌词 + 频谱。
- **暂停/后台**：`power_saver.dart` 已按最小化/失焦/熄屏压帧率；需确保**连 ticker 一起停**
  （`TickerMode`/`Visibility(maintainAnimation:false)`），而非仅降帧。

### 4.5 自适应画质

- 帧时间滑动窗口 → 档位：着色器开/关、动态层降采样倍率、涟漪上限、频谱开关。
- 复用 `FrameGovernor`/`performanceMode`；不要新增互相冲突的开关（见 §8）。

---

## 5. 分期（可验收）

| 阶段 | 内容 | 验收 |
|---|---|---|
| **R0** | profile 基线：全屏 2K/4K，记录 UI/raster 帧时间 + GPU 占用（iGPU 与 llvmpipe） | 基线与瓶颈归属报告 |
| **R1** | 背景**静态层缓存** + **动态层损伤区** + 降分辨率（§4.1） | iGPU 全屏达帧预算；视觉与上游一致；软渲染可回退 |
| **R2** | 图层纪律 + 生命周期（§4.2/§4.4）：稳定层隔离、去无谓裁剪、分支卸载、downloader 解除常驻 | RSS 可控、启动时间不退化；切页/切歌后可回收 |
| **R3** | 文本/几何批处理（§4.3，按 R1/R2 后剩余瓶颈定） | 歌词区 UI 帧时间≈常数；频谱无离屏 |
| **R4** | 自适应画质（§4.5） | 目标机稳定在帧预算内，无独显依赖 |

> 与专项文档的关系：`player-render-optimization.md` 的 **P0–P5** 仍有效；本方案的 **R1**
> 细化并**取代**其中「P2b 半分辨率」的单一手段，改为「静态层 + 损伤区 + 降采样」组合。

---

## 6. 验收与指标

- **帧时间**：DevTools Performance 分 UI / raster 线程；全屏播放页 60Hz 达帧预算（有余量再冲 120Hz）。
- **GPU 占用**：Linux `intel_gpu_top`/`radeontop`；Windows 任务管理器辅以 PresentMon/GPUView。
- **内存**：DevTools Memory，峰值/常驻 RSS；切歌、切页、退出播放页后可回落。
- **启动时间**：冷启动到首帧；模块按需后不劣化。
- **正确性/回退**：涟漪不变量与上游一致；`FragmentProgram` 不可用 / 软渲染时功能可用。
- **CI**：`dart analyze lib` 0 issue、`flutter test` 全绿（既有网络/凭据用例除外）。

---

## 7. 非目标

- **不引入 Chromium/Electron 的多进程模型**（GPU/渲染进程）：与 `AGENTS.md`
  「不新增进程承载图形/桥接、普通用户权限、同进程动态链接」冲突。
- 不自写跨平台 GPU 后端 / 不 fork Impeller；不改 Flutter 引擎。
- 不以独显为前提、不为「高级效果」牺牲 iGPU 可用性。
- 不做无度量的「感觉优化」：每期必须以 R0 指标对照。

---

## 8. 开放问题（待定）

1. **动态层选型**：§4.1 的 A/B/C 哪种在 iGPU 上最优？（怕选错，需先做小实验测填充率/分配开销）
2. **静态层载体**：`RepaintBoundary` 层缓存 vs 显式预烘焙 `ui.Image`（内存 vs 重绘/分配）。
3. **页面卸载策略**：保留状态（`PageStorage`/provider）还是直接丢弃重建？卸载触发条件（时长/内存/可见性）。
4. **画质开关**：新增统一 `effectQuality` 档位，还是继续复用 `performanceMode` 二档？
5. **测量基建**：是否能接入脚本化帧时间/GPU 采集，进 CI 或本地基准（对照 `benchmark-2026-09-10.md`）。

---

## 9. 关联文档与参考

- [player-render-optimization.md](player-render-optimization.md) — 播放页三引擎专项（背景/歌词/频谱）
- [module-on-demand-load-plan.md](module-on-demand-load-plan.md) — 原生模块按需加载与释放
- [architecture.md](architecture.md)、[benchmark-2026-09-10.md](benchmark-2026-09-10.md)、
  [test-suite-2026-09-10.md](test-suite-2026-09-10.md)
- 上游实现：`SPlayer-Next/src/components/player/FullPlayer/PlayerBackground.vue`、
  `.../BackgroundRipple.vue`
- 外部机制参考（调研自公开文档）：
  - Qt Quick Scene Graph / Performance：`doc.qt.io/qt-6/qtquick-visualcanvas-scenegraph.html`、
    `doc.qt.io/qt-6/qtquick-performance.html`（batching、preprocess/LOD、`QSGLayer`、
    「clip 不是优化」、不可见即不画、`sourceSize`、Loader/destroy、粒子不可见即停）。
  - Chromium `cc` 合成器：图层化 / tiling / partial raster / occlusion / quad batching /
    discardable memory。
  - WebRender：保留显示列表 + picture caching + atlas。
  - Flutter/Impeller：`RepaintBoundary` 层缓存、`FragmentProgram`、
    `ImageFilter.shader`（仅 Impeller，`painting.dart:4461`）、Skia `drawAtlas`。
