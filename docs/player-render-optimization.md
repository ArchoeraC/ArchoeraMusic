# 播放页渲染优化专项（Player Render Optimization）

> 状态：**进行中（2026-09-11；2026-09-20 更新；2026-11-03 更新）**——P1（歌词缓存）、P3（频谱批处理）**已实现**；
> **P0 测量基建已实现（2026-11-03）**：帧耗时分组统计（`frame_timing_stats.dart`）、
> build/paint 探针（`build_paint_probe.dart`）与「零构建」headless 回归
> （`test/frame_probe_test.dart`），见 §5.1/D1；**真机基线仍待**（本机 WSL 无 GPU）；
> **D2a 歌词墙稳态烘焙已实现（2026-11-03）**：整层档稳态每帧只贴图 + 激活行，
> 见 §4.2c；
> **歌词表现层已对齐 AMLL（§4.2b：时钟插值/羽化扫亮/景深/逐词动画/间奏点/背景人声）**；
> P2 背景：封面预烘焙 + CPU 网格已优化并生效，**全分辨率 GLSL 因集显扛不住默认关闭**；
> **P2b 由 `runtime-resource-optimization.md` R1 细化并取代**（不是单一半分辨率，
> 而是「静态层缓存 + 损伤区动态层 + 降采样」组合）；P4 字形图集 / P5 自适应画质规划中。
> 目标：消除**全屏播放页**在高刷新率 / 大面积渲染下的卡顿，并以
> **集成显卡（iGPU）为基线**（独显只作上限，不作前提）。
> 范围：播放页三块渲染重件——**高级歌词 / 背景 / 频谱**；不含列表页、设置页。
> 关联：
> [architecture.md](architecture.md)、
> [runtime-resource-optimization.md](runtime-resource-optimization.md)（跨框架机制 + 全局长效方案）、
> [rendering-reference-research.md](rendering-reference-research.md)（外部合成器渲染参考调研，2026-11-03）、
> [archive/CROSS_PLATFORM_CAPABILITY_IMPROVEMENT.md](archive/CROSS_PLATFORM_CAPABILITY_IMPROVEMENT.md)。

---

## 0. TL;DR

- 卡顿集中在**全屏播放页**，是「三块独立引擎 + 大面积画布」叠加的结果，**不是 Flutter/Impeller 引擎的问题**。
- 三块瓶颈**性质不同，必须分开优化**，不要指望一个 GLSL 方案通吃：

  | 模块 | 真正瓶颈 | 主手段 | GLSL 定位 |
  |---|---|---|---|
  | 背景（水纹/流体/模糊） | 逐像素填充率 + CPU 顶点场 | **片元着色器** | 主解 |
  | 高级歌词 | **UI 线程** `TextPainter.layout()` + 逐行 `saveLayer` | **Paragraph 缓存 + 字形图集批渲染** | 仅后处理特效 |
  | 频谱 | draw call 数量（每 bar 一次 `drawRRect`） | **批处理** | 基本不需要 |

- **渲染器（GPU）优先**：默认走 GPU 路径；**仅当 GPU 路径彻底失败**（着色器编译失败、
  后端不支持、软件渲染）才回退 CPU，CPU 只作最后兜底而非并列选项。
- **iGPU 优先**：iGPU 瓶颈是填充率 / 带宽 / overdraw，不是算力。核心纪律：
  效果层**降分辨率**、**合并全屏 pass**、**限制逐像素工作量**、**只用通用着色器特性**、
  **自适应降级**。
- **先测量再动手**：用 `flutter run --profile` + DevTools Timeline 区分 UI 线程 vs raster
  线程瓶颈，按实测命中排序，不拍脑袋。

---

## 1. 症状与初步定位

### 1.1 症状

- 全屏（尤其 2K/4K、120Hz）下播放页明显掉帧；窗口态较轻。
- 窗口越大越重 → 与**填充率/面积**强相关，而非纯逻辑。

### 1.2 嫌疑点（待 profile 复核，勿直接下结论）

1. **背景** `app/lib/widgets/player/player_background.dart`
   - `ripple`：CPU 逐顶点涟漪场（`ripple_background.dart:376` `_computeField`），
     网格上限 `160×90 ≈ 14,400` 顶点（`:340`），每顶点遍历最多 48 个涟漪，
     每个涟漪 `sqrt + exp×2 + sin`（`:397-402`）→ 单帧数千万次超越函数，全在 **UI 线程**；
     再叠 `14px ImageFiltered` 模糊 + `ColorFiltered` 饱和 + 交叉淡入 `saveLayer` + 3× `drawVertices`。
   - `blur`：全屏 `sigma 45` 模糊 + 1.5 放大（`player_background.dart:99`），**纯填充率成本**，全屏最贵。
   - `gradient`：近乎零成本（若用户实际用默认档，GLSL 背景纯属白做）。
2. **高级歌词** `app/lib/widgets/player/lyrics_v7/lyrics_physics_wall/lyrics_physics_wall_painter.dart`
   - `paint()` 对**每个可见行每帧**新建 `TextPainter` 并 `layout()`（`:51`、`_painterFor` `:96`）；
   - 每行一次 `saveLayer`（`:53`）——离屏渲染目标，iGPU 上尤其贵；
   - 翻译行再建一个 `TextPainter`（`:72`）。
   - 简单引擎 `LyricsView` 更甚：每次 build 对**全部行**重算高度（`lyrics_view/lyrics_view_widgets.dart:18-21`）。
3. **频谱** `app/lib/widgets/player/spectrum_view/spectrum_view_painter.dart`
   - 20fps 重绘（`pushIntervalMs = 50`），`bars` 模式每根 bar 一次 `drawRRect`（`:125`）；
     宽屏下 bar 数多 → draw call 多。量级最小，优先级最低。

### 1.3 必须区分线程

- **UI 线程**贵 → 歌词排版 / 水纹 CPU 场 / 每帧 Dart 计算；
- **raster 线程**贵 → 全屏模糊 / `saveLayer` / 大面积绘制 / overdraw。
- 两者解法不同：GLSL 只解决 raster 侧；UI 侧要靠缓存与批处理。**用错地方会「看着高级但没变快」。**

### 1.4 实测线索（2026-09-11）

- 用户观测：**全屏播放页 GPU 占用极高**（Windows 任务管理器）。这与「raster / 填充率瓶颈」
  的推断一致：当前最烧 GPU 的是全屏 `ImageFiltered` 模糊（`sigma 14`/`45`）、`ColorFiltered`
  饱和、逐行 `saveLayer` 与 overdraw——正是 P2「半分辨率 + 合并 pass」的打击对象。
- 注意：任务管理器 GPU% 是粗指标（含 DWM 合成、可能只反映单一引擎利用率），**不能单独作结论**；
  判定以 DevTools raster 帧时间为准，Windows 可辅以 PresentMon/GPUView。
- 结论：**渲染器（GPU）路径是主线**，CPU 路径只在 GPU 路径彻底不可用时兜底（见 §3.3）。

---

## 2. 现状盘点（引擎边界）

| 引擎 | 文件 | 状态 | 备注 |
|---|---|---|---|
| 背景 | `player_background.dart` + `ripple_background.dart` / `fluid_background.dart` | 活跃 | 5 档：gradient/blur/solid/ripple/fluid |
| 高级歌词（v7） | `lyrics_v7/lyrics_physics_wall.dart` | 活跃 | 自研布局 + 闭式弹簧 + CustomPainter |
| 简单歌词 | `lyrics_view.dart` | 活跃 | 回退档 |
| 频谱 | `spectrum_view/spectrum_view_painter.dart` | 活跃 | bars/wave/waveUp |
| ~~`AmllWall`（v5）~~ | ~~`amll_wall_v5.dart`~~ | **已删除** | 无引用 |
| ~~`AmllLyricWall`（稳定版）~~ | ~~`amll_lyric_wall*.dart`~~ | **已删除** | 仅死测试引用 |

> 说明：v7 引擎已有独立**布局**（`lyrics_v7/lyrics_layout.dart`，`TextPainter` 实测行高/自然中心，缓存）、
> 独立**物理**（`lyrics_v7/spring.dart`，闭式解 `Spring1D`，廉价）、独立**绘制循环**
> （`CustomPainter` + `_Repaint` + `Ticker`，弹簧停即停表）。**残血之处：它把「文字」这件最贵的活
> 外包给了 Flutter 的 `TextPainter` 每帧现排。**

---

## 3. 设计原则

### 3.1 三个引擎分开

- 不追求「统一渲染框架」：背景是逐像素、频谱是几何批处理、歌词是字形排版，硬凑只会三方都别扭。
- **只共用基建**：`FragmentProgram` 资产加载与实例缓存、性能开关、`RepaintBoundary`/图层策略、自适应画质。
- 每块可独立开关、独立降级、独立回退。

### 3.2 iGPU 优先（硬约束）

iGPU 瓶颈 = 填充率 / 显存带宽 / overdraw。原则：

1. **效果层降分辨率**：水纹 / 模糊在 **1/2 或 1/4 分辨率**离屏纹理上算，再放大合成（最有效，全屏模糊直接省 4~16×）。
2. **合并全屏 pass**：当前 `blur + saturate + ripple + darken` 是 4 遍全屏；目标压成 **1~2 遍**。
3. **限制逐像素工作量**：降涟漪数、避免逐像素重复 `exp/sin`，或把场预计算进小纹理采样。
4. **只用通用特性**：`sampler2D` + 小 uniform 数组；**不用** compute / storage buffer / 大 UBO（iGPU 与老驱动不可靠）。
5. **不依赖独显能力**：无 MSAA 高倍、无几何/网格着色器、无光追。
6. 避免高成本 `ImageFilter`：全屏 `sigma 45` 属于红线级，必须降采样或改单 pass 近似。

### 3.3 渲染器优先，CPU 仅兜底

- **默认一律走 GPU 渲染路径**（`FragmentProgram` / `drawAtlas` / 批处理）。
- **仅当 GPU 路径彻底失败**才回退 CPU：
  - `FragmentProgram.fromAsset` 加载/编译失败，或后端明确不支持该能力；
  - 运行在软件渲染（llvmpipe / SwiftShader）等无 GPU 场景。
- CPU 路径是**最后兜底**，不参与常规档位选择，不作为性能选项暴露给用户。
- **自适应降级**：按实测帧时间在 **GPU 路径内部**动态减档（效果分辨率、涟漪数、模糊开关），
  而非直接退回 CPU。
- 提供 `性能 / 均衡 / 画质` 档位，默认按 GPU 能力 + 帧时间自动；复用既有 `performanceMode` 开关。

### 3.4 内存预算与缓存纪律

- 目标：歌词渲染**常驻内存 ≤ ~5 MB，且与歌长无关**。
- **`ui.Paragraph` 缓存**：按**可见窗口 ± N**（约 10~20 行 + 余量）缓存，滑出窗口即淘汰；
  单段约 1~3 KB，即使全量缓存一首歌也仅 ~0.3~1 MB，但**不做全量**，保持 O(视口)。
- **字形图集（glyph atlas）**：单张纹理，按实际唯一字形增长；优先 **R8 灰度 / SDF**，上限 ~4 MB；
  字号档 / 字体变化时重建。中文唯一字约 500~1500，28px 下 RGBA 最多 ~6 MB、R8 ~1.5 MB。
- **生命周期**：切歌（`groups` 变化）**整体失效**，不跨歌保留；`performanceMode` / 不可见时停表并可清缓存。
- **现状对照**：每帧 `new TextPainter(...).layout()` 属瞬态分配 + GC 抖动；缓存是「有界常驻换 CPU」，
  稳态内存不升反降。对比参考：一张 1024² 封面解码即 4 MB，歌词缓存小一个量级。
- **校验**：DevTools Memory 实测峰值与常驻，纳入 P1/P4 验收。

---

## 4. 分模块方案

### 4.1 背景 → `FragmentProgram`（主解，P2 已实现）

- `app/shaders/ripple.frag`：**单 pass** 完成折射 + 饱和 + 波峰高光/波谷压暗 + 压暗；
  `pubspec.yaml` 增 `flutter: shaders:`；`RippleShaderLoader` 启动 `FragmentProgram.fromAsset`
  并缓存 `FragmentShader`（`app/lib/widgets/player/ripple_shader.dart`）。
- Uniforms 扁平布局（`RippleUniforms`，含与 `ripple.frag` 一致性的单元测试）：
  `uSize`、`uDarken`、`uSaturation`、`uImgAspect`、`uMix`、`uRipples[48]`（x,y,radius,amp）、
  `uSeeds[48]`、`uCount`；sampler：`uCoverFrom`/`uCoverTo`。
- **封面模糊/饱和预烘焙一次**（Dart 离屏，封面变更时重做），取代原先**每帧全屏
  `ImageFiltered` 模糊**——这是 P2 的最大 raster 收益；`saturate/darken` 已并入 shader。
- 交叉淡入在着色器内以 `uMix` 混合两纹理，仍为单 pass。
- **`FragmentProgram` 加载失败**（或 `flutter test` 软件渲染）→ 回退现有 `_RipplePainter`
  （CPU 网格折射）。
- 不变量：涟漪随机序列、生命周期、速度、间距、交叉淡入与上游一致。
- ⚠ **实测（2026-09-11，Intel Raptor Lake-S UHD 核显，Mesa/Impeller GLES）**：
  全分辨率逐像素 48 涟漪的着色器**远超帧预算**，导致全屏整体掉帧（表现为歌词“无法滚动”）。
  **故默认关闭着色器路径**（`kEnableRippleShader = false`），改走优化后的 CPU 网格：
  - 封面模糊/饱和**预烘焙一次**（已去掉每帧全屏 `ImageFiltered`）；
  - 涟漪场**逐顶点 `|dw|>0.5` 裁剪 + 每涟漪预计算 amp**，把 CPU 代价压到可负担。
- **P2b（→ 由 R1 取代）**：原本设为「低分辨率（1/2~1/6）离屏降采样」；现**升级**为
  `runtime-resource-optimization.md` §4.1 的 **R1**——「静态层缓存一次 + 动态层只画损伤区
  （活动涟漪波带）+ 降采样」三段组合，并给出 A/B/C 三种实现选型（§8.1）与回退阶梯。
  重开 `kEnableRippleShader` 不再是前提，而由 R1 实测决定。

- **`blur` 档同样预烘焙一次（2026-09-30）**：`blur` 背景原先用
  `ColorFiltered(ImageFiltered(blur σ=45))` 实时包裹封面——Impeller 已把 `flow`
  的图层光栅缓存编译掉（仅 Skia 有），播放页每帧重绘（歌词/频谱/进度）都会
  **全屏重算高斯**；Windows 上这些离屏缓冲按进程内存计账（WDDM/ANGLE），是
  「播放页吃内存」的主要来源之一。现改为 `BlurredCover` 在封面/尺寸变化时把
  「cover 适配 → 放大 1.5 → 模糊 → 饱和」**烘焙成一张 `ui.Image`**（分辨率长边
  封顶 2048），每帧只 `RawImage` 贴图；切歌仍保留两层交叉淡入（各烘焙一次）。
  实时滤镜仅在烘焙不可用（`flutter test` 软渲染 / `toImageSync` 失败）时回退。

### 4.1b 流体背景（对齐上游 AMLL `MeshGradientRenderer`，P2 已实现）

上游 SPlayer-Next 的 `playerBgType: 'animation'` 是 AMLL 的 WebGL 网格渐变：每首歌随机
一个双三次 Hermite 控制点网格（subdiv=50）形变封面，片元再绕 `(0.2,0.2)` 旋转（时间+音量）、
按 `1-音量` 缩放、dither、晕影，切歌 alpha 0→1.1 交叉淡入。Flutter 端落法：

- **Hermite 形变一次性烘焙为位移贴图**（`fluid_mesh.dart`）：
  `buildFluidWarpMesh` 逐行照搬上游 `updateMesh`（含 gl-matrix 列主序矩阵与 5 组预设 /
  `cp-generate` 随机生成），把「未 aspect 校正的 NDC `pos` → 纹理坐标 `v_uv`」前向栅格化
  进 `drawVertices`（顶点色 = RG 存 `v_uv`，`BlendMode.dst`），`Picture.toImageSync` 出图。
  **每首歌只烘焙一次**（`256×256`，subdiv=50），窗口缩放不需重烘焙。
- **片元单 pass**（`app/shaders/fluid.frag`）：屏幕 uv → **逆 aspect**（还原上游顶点着色器）
  → 查位移图得 `v_uv` → 旋转/缩放 → **镜像重复**采封面 → 音量 alpha/晕影/dither → 预乘输出。
  uniform 扁平布局 `FluidUniforms`（uSize/uAspect/uVolume/uSinAngle/uCosAngle/uAlpha，
  sampler uWarp/uCover），含与 `.frag` 一致性的单元测试。
- **封面预烘焙**（`fluid_cover.dart`）：封面压到 32×32 → 上游四步色调（对比度 0.4 →
  饱和 3.0 → 对比度 1.7 → 亮度 0.75，中间不夹取故合并成**单个颜色矩阵**）→
  `blurImage(radius=2, quality=4)` 盒式模糊，均为纯 CPU 字节运算，逐位移植且可单测。
- **多状态交叉淡入**：每个曲目状态持有（位移图, 封面）与 alpha，按序叠加绘制
  （`drawRect` 时引擎会**拷贝** uniforms，故复用同一 `FragmentShader` 安全）；旧状态在
  新状态 alpha 达 1.1 后释放。上游 `meshStates` 语义一致。
- **设置项完整对齐上游**：`player.playerBg*` → 流速（0.1~10，默认 4）/ 渲染比例
  （0.5~2，默认 0.5，`renderScale` 低分辨率离屏）/ 帧率上限（24~120，默认 30）/
  暂停冻结（默认 false）/ 低频节拍脉动（默认 false，移植 `getBassPulse` 80~180Hz +
  attack/decay 平滑）。性能模式停表呈现静态帧。
- **回退**：着色器不可用 / `ARCHOERA_FLUID_SHADER=0` / 位移图烘焙失败 / `flutter test`
  软件渲染 → 「预烘焙封面直铺」，不崩不空。

### 4.2 高级歌词 → 字形引擎（不上 GLSL 做排版）

分三步，风险递增、收益递增：

1. **Paragraph 缓存 + 去 `saveLayer`（先做，收益最大、不需 shader）**
   - 每行 / 每片段用 `ui.ParagraphBuilder` 建 `ui.Paragraph` 并缓存（文本/字号/字体/宽度变才重建）；
   - **缓存按可见窗口 ± N（见 §3.4），非全量**；
   - 逐字进度只改颜色，不再 `layout`；
   - 去掉逐行 `saveLayer`：alpha 写进 `TextStyle.color`；缩放用 `canvas.scale`（无需离屏）。
2. **逐字符精灵图集批渲染（变体 A，P4 待实测后定）**
   - **公开 API 限制**：`dart:ui` 只暴露**字符**包围盒（`Paragraph.getBoxesForRange`），
     **不暴露字形 ID/位置**，故无法做真正的 glyph 级图集。
   - 可行替代：每个唯一字符各自渲成精灵（`ui.Paragraph` → `toImage`）缓存，按已缓存字符 box
     定位，用 `Canvas.drawAtlas` + 每字 `Color` 一次批量画完整行（逐字扫亮可行）。
   - 代价：无连字、组合字符/RTL 边缘复杂，工作量大；且 **P1 已消除每帧 shaping 与 `saveLayer`**，
     残留仅 ~15 次 `drawParagraph` + 活跃行 1 次 shaping/帧 → **边际收益变小**。
   - 结论：**先由 P1–P3 实测决定是否需要 P4**（见 §6.1）；需要再做变体 A。
3. **后处理（可选，GLSL 的正确落点）**
   - glow / blur / 色散等逐像素效果，对**已合成的歌词图层纹理**做 `FragmentProgram`；
   - 半分辨率、单 pass。

- 简单引擎 `LyricsView` 的 O(N) 每 build 全量测高同样按 1 收敛。
- **简单引擎（默认档）位置 tick 只重建当前行（2026-11-03）**：位置 tick（~20Hz）
  原先会让整个 `ListView` 重建全部可见行；现非当前行返回**缓存的同一 widget
  实例**（`Element.updateChild` 对 identical widget 短路 → 不重建、不重绘），
  行高列表也只在「当前行翻转 / 分组 / 宽度 / 样式」变化时重算（换行约每几秒
  一次，而非每 tick 跑 O(行数)）。当前行因逐字扫亮仍每 tick 重建（必要）。
  回归：`test/lyrics_view_rebuild_test.dart`（20 tick 内构造 ≤ 当前行数、缓存
  命中 ≥ tick 数；跨行翻转不串行）。
- **歌词上下渐隐 / 全屏封面右缘渗入：保持 `ShaderMask`（dstIn）**。
  2026-11-03 曾尝试「`RepaintBoundary` + dstOut 叠加」免每帧离屏层——软件
  光栅下逐像素等价（差 ≤ 2/255）、测试通过，但**真机上 dstOut 未被边界
  隔离，把歌词列下层页面背景擦成深色块**，已回退。教训：跨图层混合模式
  的等价性不能只靠软件光栅像素测试验证，真机必须过一遍。

#### 4.2b 表现层：AMLL 效果对齐（2026-09-20 已实现）

P1 只解决了「排版权」成本；**观感**与上游 AMLL 仍有明显差距（AMLL 是 DOM + Web
Animations，逐 `<span>` 可独立变换）。本轮把 AMLL 的表现层补齐到 Flutter：

| 能力 | 实现 | 成本 |
|---|---|---|
| 播放时钟插值 | `lyric_clock.dart`：~20Hz 位置事件外推 + 上限 150ms；播放中 ticker 常开 | 播放中持续重绘（60fps） |
| 逐字渲染 | `lyrics_fragment_render.dart`：整行段落取 `getBoxesForRange` 逐字盒 + 逐字左对齐小段落（缓存） | 每行 1 次整行 layout + 2N 次小段落（换行时一次性） |
| 羽化扫亮 | 逐字 dstIn 线性渐变遮罩（未唱 α0.4 → 已唱 α1.0），当前扫过字 1 层 `saveLayer` | 每帧 1 层（仅激活行） |
| 景深 | 非激活行失焦（默认「整层一次 + 1/4 重采样」，可切逐行 σ=`min(5,1+距离)`）+ 弹簧化 `scale 0.97` + 距离透明度；帧预算守卫自动降级 | 默认档每帧 **1** 个离屏层（像素量 1/4）；逐行档 ≈ 可见行数层 |
| 逐词上浮/长音强调 | `lyrics_word_anim.dart`（AMLL float + emphasize 脉冲：辉光/缩放/推挤/bob） | 长音字/词每帧重建 1 个小段落 |
| 间奏三点 | `interlude_dots.dart`（≥7s 空隙；依次点亮 + 呼吸 + 两段退场） | 3 个圆，可忽略 |
| 背景人声行 | 解析整行括号 → `isBG`；0.7× 字号、0.4 透明度、以 0.4× 行距挂在上一行下方（占位，不再与下一行重叠） | 无额外成本 |
| 行距/行高度量 | `kLyricLineHeightEm 1.2` + `kLyricLineGapEm 1.0`（AMLL wrapper 内边距等效 0.8，适度放宽） | 无 |
| 换行弹簧 | `spring_policy.dart`：按行间隔自适应（170~220，ζ≈1.1 不过冲）；仅播放推进带级联；新歌整墙飞入 | 无（减少过冲反而更省重绘） |
| 音译（罗马音） | 来自 main：`LyricGroup.romaji` + `showRomanization`，绘制在译文**之上** | 每行多 1 个小段落（可选） |
| **视口窗口化**（2026-09-20） | 只有视口 ± 自适应余量内的行参与弹簧/过渡（窗口外 `park()` 不重建求解器）；行高按需实测（视口外用估算）；重绘抑制（无变化不 notify）；失焦两档 + 自动降级 | 换行/每帧/字号变化的成本都从 **O(歌长) → O(视口)**；失焦从「≈可见行数层」降到「1 层」 |
| **失焦帧预算守卫**（2026-09-20） | `LyricsBlurBudget`：歌词墙在动时连续多帧「光栅超 14ms 且 UI 线程正常」→ latch 成关闭失焦 | 弱机/软件光栅上不会因为失焦持续掉帧（§4.2.1） |

- **性能纪律**：所有新效果都受 `animate`（性能模式）与 `amll.enableBlur` /
  `amll.enableScale` 开关约束；性能模式下直接吸附目标值、无 ticker。
- 详细设计/对齐清单/刻意简化项见 [lyrics-amll-alignment.md](lyrics-amll-alignment.md)。

### 4.2c 整层档稳态烘焙（D2a，2026-11-03 已实现）

> 思路参考外部合成器渲染调研的「显式栅格化」纪律（Impeller GLES 下 raster cache
> 关闭）与「模糊成本 = 离屏层数 × 像素量」结论；自研实现，出处与许可证边界见
> [rendering-reference-research.md](rendering-reference-research.md) D2/D4。

**问题**：整层档（默认）每帧执行「整层 saveLayer（物理分辨率离屏 target）→
compose 滤镜链（降采样 → blur → 升采样）」，且非激活行段落全部重放——这是
播放页稳态最大的单项 raster 开销，但稳态下非激活外观**完全不变**。

**方案**（`lyrics_physics_wall_bake.dart` `_WallBake`）：

1. **稳态判定**：非激活外观静止（弹簧/过渡/浏览均无变化，`staticIdle`）+
   整层强度已落定（`blurStrengthSettled`）+ 激活外观完整（fade==1）+ 缩放终值。
2. **逐行烘焙**（保观感是硬要求）：每静态行独立走
   「行内容**物理分辨率**栅格 → 双线性降采样到 1/4 逻辑网格 → blur(σ·k) →
   存 1/4 小图」——与旧滤镜链的采样步长逐像素同源；单行全分辨率中间图
   随建随弃（峰值数 MB），**不做整墙全分辨率中间图**（4K ~75MB，红线）。
   常驻内存 ≈ 视口/16（1080p≈0.5MB、4K≈2MB），O(视口)。
   **缓存与位置无关（2026-11-03 修正）**：烘焙内容只取决于行内容/样式，
   y / 激活行 / 淡入权重都在绘制时应用（y → 贴图目标矩形、alpha → 贴图
   着色；高斯对 alpha 线性，故可后乘）。换行/滚动**不使缓存失效**——每次
   换行只为新进入视口的行烘 1~2 张，不再把可见十几行全量重烘（那会在换行
   后首帧造成一次明显尖峰，真机 FrameTiming 图可见）。
3. **稳态每帧**：逐行 `drawImageRect` 贴图 + 激活行（clipRect 替代 α=1 的
   saveLayer）+ 间奏三点。**整层高斯 saveLayer 与全部非激活段落重放消失**。
4. **过渡帧**（换行级联/悬停/seek/浏览）：**基座同样复用烘焙图**（行在动，
   但模糊外观不变 → 贴图跟随 y 移动即可；激活外观仍逐帧重绘），
   仅在强度动画中（悬停渐变）回退逐行统一 σ 高斯。观感等价实测：过渡帧
   「缓存贴图 vs 逐行高斯」mean 差 **1.20**/255、高差像素 **0.50%**。
5. **失效判定 = 样式键**：缓存键只含**影响非激活外观**的量（行内容/样式、
   字号/字重/字体、颜色、行距相关的行高、σ、缩放终值、DPR），不含 y / 激活行 /
   淡入权重 / 可见集合——这些都在绘制时应用，因此换行、滚动、seek 都不失效。
6. **烘焙摊帧**：绘制路径**只查不烘**（`lookup`），缺失的行本帧回退逐行高斯
   （观感等价）；稳态帧用 `prefetchOne` 每帧最多烘 1 张，预取视口上下各 2 行。
   这样「新行进入视口的那一帧」不再有 3 次 `toImageSync` 与光栅线程串行。
7. 逐行档 / 轻量档 / 关闭档不烘焙（逐行档的稳态优化可后续按同思路做）。

**观感变化（需在发版说明注明）**：标定发现旧整层滤镜链在 Impeller 下的实际
渲染**带各向异性拖影伪影、等效模糊约 3× 于设计值**（blur σ 按「矩阵变换后
空间的物理像素」解析所致；2026-09-21 的 σ 3.0→4.0 调参是在该伪影基础上做的）。
现整层档统一为**干净的 σ=4 单峰高斯**（对齐 AMLL 设计值），静止歌词明显
更清晰；标定数据：旧链 vs 干净高斯逐像素 mean 差 2.89、>32/255 像素 3.57%
（无法用任何对称高斯复刻旧伪影，故放弃「逐像素复刻」目标）。

**验收**（`test/lyrics_bake_test.dart`，headless 可复现）：

- 稳态帧走烘焙贴图（`debugBakeActive()`）；换行过渡回退逐行、收敛后恢复；
- 观感等价（统计口径）：烘焙贴图帧 vs 过渡逐行帧 mean 差 ≤ 8/255 实测
  **0.98~1.18**、高差(>32)像素 ≤10% 实测 **0.35%**；
- 既有歌词墙回归（锚点/换行/seek/浏览/缓存有界）全绿。

**真机验证（待办）**：带 GPU 的 Windows/Linux 上 A/B（`ARCHOERA_LYRICS_BLUR=panel`
+ 烘焙开关）确认帧时间与观感；弱机确认 LyricsBlurBudget 行为不变。

### 4.2d 上下渐隐：逐行 alpha（默认）vs ShaderMask（2026-11-03）

**问题**：歌词列上下渐隐用外层 `ShaderMask`（dstIn），每帧对**歌词列面积**
创建一次离屏层（全屏 2K/4K 下面积线性增长）；全屏封面右缘渗入是第二处同类
开销。这两处是播放页里仅剩的「每帧 × 面积」离屏层（其余背景/歌词/频谱都已
改成预烘焙贴图或单 pass）。

**结论**：默认改为 `wall`（逐行 alpha，零离屏层）。等价性实测（400×500、
默认字号、`test/lyrics_edge_fade_test.dart`）：逐行 vs `ShaderMask` 逐像素
**mean 0.07/255、最大差 9/255、>32 像素 0%**——差异只在最上/最下 1~2 行的
行内梯度，肉眼不可辨；而省掉的是一整个歌词列面积的离屏层（全屏约占半屏）。

**开关**：设置页「性能 / 渲染 → 歌词边缘渐隐」（偏好键 `render.lyricsEdgeFade`，
默认 `wall`，可切「逐行 / 遮罩 / 关闭」）。环境变量 `ARCHOERA_LYRICS_FADE`
优先级更高，用于现场 A/B（不改设置、不重编译）：

```bash
ARCHOERA_LYRICS_FADE=wall     # 默认：物理墙逐行 alpha（仅 amll 引擎）
ARCHOERA_LYRICS_FADE=shader   # 回退：外层 ShaderMask（任意引擎都正确）
ARCHOERA_LYRICS_FADE=off      # 不渐隐（仅诊断，会露硬边）

ARCHOERA_COVER_MASK=off       # 跳过全屏封面右缘渗入遮罩（仅诊断，会露硬边）
```

- `wall` 由 `AmllPhysicsWall.edgeFade` 驱动：每行按**行中心**取
  `lyricsEdgeFadeAt(y/h)`，乘进该行的基础层/激活层透明度（贴图路径乘
  `Paint.color` alpha，与烘焙的位置无关缓存天然兼容）。
- 曲线与 `LyricsEdgeFade` 的停点逐段一致（`test/lyrics_edge_fade_test.dart`
  断言停点、夹紧、中段恒 1）。
- simple 引擎未接入逐行模式（列表项是独立 widget，需逐项传 alpha），自动回退
  `shader`。

**成本模型（为什么全屏才严重）**：

| 元素 | 每帧成本 |
|---|---|
| 歌词墙稳态（烘焙） | 可见行数 × 行贴图面积 ≈ 视口/16 的采样 + 一次填充 |
| 歌词渐隐（默认 `wall`） | 0（逐行 alpha 乘进绘制颜色） |
| 歌词渐隐（`shader` 回退） | 歌词列面积 × 2（写入离屏 + 合成） |
| 封面渗入 `ShaderMask` | 封面面板面积 × 2 |
| 背景（gradient/blur 烘焙） | 1 次全屏贴图 |
| 频谱 | 90px 高条带，按帧步长重绘 |

窗口态下 `ShaderMask` 的面积只有全屏的 1/4~1/16，所以「窗口看着没事、
全屏极为严重」正是它们的特征。剩下的封面遮罩可用 `ARCHOERA_COVER_MASK=off`
单独测占比（下一步候选：把「封面 + 遮罩」一次性烘焙成贴图，见 §5.1）。

### 4.2.1 失焦策略基准与选择（2026-09-20）

**动机**：对齐 AMLL 的「除高亮行外全模糊」后真机出现明显卡顿。失焦是本引擎
唯一的重光栅项，必须先把成本量出来再选画法，而不是凭感觉调参。

**方法**（可在任意机器复现，不需要 GUI）：`flutter test` 里录制同一场景的
`Picture`，`await picture.toImage(900, 600)` 真栅格化并计时；场景 = 26 行、
字号 44、连续滚动（每帧滚动 1.6px，保证不复用任何缓存）。

**环境**：本机是 WSL、**无 GPU 节点**（`/dev/dri` 不存在）、软件光栅（llvmpipe），
即**最坏情况**；绝对值不代表独显机器，但「层数/像素量决定成本」的排序是通用的。

| 策略 | p50 ms/帧 | 相对无失焦 |
|---|---|---|
| 无失焦 | **6.3** | 1.0× |
| 逐行 bounded blur（旧默认，σ=0.5×(1+d)） | 28.5 | 4.5× |
| 逐行 σ 再减半 | 49.7 | 7.9× |
| 逐行 bounded blur @1/4 分辨率 | 24.5 | 3.9× |
| 整层一次 blur σ=1.5 @1/1 | 39.4 | 6.3× |
| 整层一次 blur σ=1.5 @1/2 | 23.3 | 3.7× |
| **整层一次 blur @1/4（现行默认）** | **16.2** | **2.6×** |
| 整层一次 blur @1/8 | 14.7 | 2.3× |
| 整层一次 blur σ=2.5（AMLL 上限）@1/4 | 16.5 | 2.6× |
| 零高斯「假失焦」（缩放+透明重绘） | 7.7 | 1.2× |

**结论**：

1. 成本由**离屏层数 × 模糊像素量**主导，**σ 影响很小**（16.2 vs 16.5；甚至更小的
   σ 因算法分支反而更慢）→ 所以「把 σ 调到 AMLL 原值、让观感更准」几乎免费。
2. 「整层一次」在 1/1 下**不比逐行便宜**（面积更大）；只有在**降采样**后才赢
   ——这正是选「整层 + 1/4」而不是「整层 + 原分辨率」的原因。
3. 因此 `auto`（默认）/`fast` 档都走 `panel`（整层 + 1/4 重采样，用
   `ImageFilter.compose` + `ImageFilter.matrix` 实现，**不产生纹理缓存、不占显存**），
   追求上游半径梯度的机器可在设置里选 `quality`（逐行）。用户也可直接选 `off`
   ——三类机器（独显/核显/无 GPU）的需求差别太大，**把决定权交给用户 + 自动兜底**；
   弱机上还可选零高斯的 `lite`（轻量）档。
4. 再往下（@1/8）收益递减，且过糊。**零高斯「假失焦」（轻量档）已实现为可选档**：
   基准 7.7ms ≈ 无失焦成本，观感是重影式柔化（与高斯不同）—— 给吃不住任何高斯层的
   核显/软件光栅留一个「有景深但不卡」的选项，由用户在设置里自行选择。
5. **真机确认方式**：设置里选档位（`amll.blurQuality`），或诊断用环境变量
   `ARCHOERA_LYRICS_BLUR=perline|panel|off` 启动 A/B（显式指定会禁用自动降级）。⚠ 待办：在带 GPU 的 Windows/Linux 真机上复测
   （本机 WSLg 起不了 GUI，Impeller 的 blur 实现与 Skia 不同，见 flutter#191207）。

### 4.3 频谱 → 批处理（P3 已实现）

> **v2（2026-11-04 设计）**：频谱分析整体下沉引擎（[`spectrum-analyzer.md`](spectrum-analyzer.md)），
> UI 只做事件接收 + 插值/显示平滑/绘制，不再拉 PCM/调 FFI；本节 P3 的
> 单 Path 批处理与画笔渐隐继续有效。

- FFT 平滑仍在 CPU（廉价，且需跨帧状态）；
- `bars`：所有柱子合成**单个 `Path`（多个 RRect）一次性 `drawPath`**，替代 N 次 `drawRRect`；
  保留圆角与几何，视觉不变；
- 横向渐隐从 widget 侧 `ShaderMask`（离屏层）**并入画笔 `LinearGradient` shader**，去掉一次合成
  pass；`wave`/`waveUp` 同样改用该画笔 shader；
- 重绘频率维持插值所需的每帧（不改）。

### 4.4 共用基建

- `FragmentProgram` 加载 + `FragmentShader` 实例缓存（背景、歌词后处理共用）。
- 统一性能开关与「不可见即停表」。
- 统一 `RepaintBoundary`/图层隔离策略。
- 帧测量基建（2026-11-03）：`frame_timing_stats.dart`（分位数分组）+
  `build_paint_probe.dart`（build/paint 探针）；歌词墙已建立「0 build」基线
  （`test/frame_probe_test.dart`），D2 Retained 化改造前后共用同一断言。
- **共享模糊输入（D3，2026-11-03 已实现）**：`GlassBlur.backdropIsBakedBlur`
  ——调用方保证面板背后只有预烘焙的模糊背景（图片风格壳层背景是一次烘焙的
  模糊壁纸）且无动态内容穿过时，免掉 `BackdropFilter`（对已模糊图再做 σ16
  高斯视觉近乎无差，却每帧付整条离屏 pass）。**落点：停靠播放条**（内容层
  已让位 82px，`player_bar_sections.dart`）。悬浮播放条 / 搜索下拉 / 队列
  面板 / 登录弹窗背后有动态内容，**保留真毛玻璃**（正确性优先）。
- **遮挡显式隐藏（D6，2026-11-03 已实现）**：`/player` 路由是
  `opaque: false`，播放页完全展开后壳层仍会被绘制——壳层背景（全屏贴图）
  与停靠播放条被播放页整幅不透明背景完全盖住。用 `OffstageWhenComplete`
  （`widgets/common/offstage_when_complete.dart`）在路由动画完成（≥0.999）
  后停绘二者，**保留 element/state**（返回无重建闪烁）；播放页收起过渡期间
  自动恢复绘制。
- 统一自适应画质控制器（帧时间滑动窗口 → 档位）：**首个落地是歌词失焦**
  （`lyrics_blur_budget.dart`，§4.2.1），后续频谱/背景可复用同一守卫。

---

## 5. 阶段计划（可验收）

| 阶段 | 内容 | 验收 |
|---|---|---|
| **P0 部分✅** | 测量基建（2026-11-03）：`FrameTimingStats`（build/raster/队列/vsync 分组，avg/p50/p95/p99/max，环形 600 帧）+ `BuildPaintProbe`（build ≠ paint 分开计数）+ `test/frame_probe_test.dart`（歌词墙连续滚动 60 帧 **0 build** 基线）；FPS 浮层展开态显示 UI/R/队列 p50/p95。**真机 profile 基线仍待**：全屏 2K/4K、120Hz | 产出基线与瓶颈归属报告 |
| **P1 ✅** | 歌词：Paragraph 缓存（可见窗口）+ 去 `saveLayer` | 全屏歌词区 UI 线程帧时间显著下降；歌词回归测试全绿；常驻内存符合 §3.4 |
| **P2 ✅** | 背景：`FragmentProgram`（单 pass + 封面模糊预烘焙；CPU 仅失败兜底） | 着色器四后端（SKSL/GLES3/Vulkan/Metal）编译通过；CPU 回退可用；三端视觉/帧时间待真机 |
| **P2b** | 半分辨率离屏降采样（仅当实测 iGPU 仍不足） | 帧时间进一步下降、视觉可接受 |
| **P3 ✅** | 频谱：单 Path 批量 + 渐隐并入画笔 | 无 `ShaderMask` 离屏层；三样式冒烟测试绿 |
| **P4** | 逐字符精灵图集（公开 API 限制，见 §4.2；待 P1–P3 实测后定） | 歌词区 UI 线程≈常数（与行数弱相关） |
| **P5** | 自适应画质 + 档位 | **部分✅（2026-11-03）**：`QualityGovernor` 接线——涟漪/流体 `renderScale` 按档位降采样、频谱降重绘频率（不关闭）；默认开启。歌词失焦仍由 `LyricsBlurBudget` 独立守卫。**真机验证待做** |

> 顺序原则：**先 P1（收益最大且不依赖渲染后端）→ 再 P2**；P3 随时可插；P4/P5 视 P1/P2 后剩余瓶颈决定。

### 5.1 补充候选（2026-11-03，源自外部合成器渲染调研）

> 来源与许可证边界见 [rendering-reference-research.md](rendering-reference-research.md)
> （参考项目 GPL-3.0：只借鉴思想/方法/实测结论，**自研实现，不抄代码、不照搬命名**；
> 项目名称仅登记于 `acknowledgements.md`，本仓文档/模块不以之命名）。
> 均为**候选**，是否排期由 P0 实测决定。

| 项 | 内容 | 对应调研条目 |
|---|---|---|
| **P0 补全** | 帧指标分组（FrameTiming avg/p50/p95/p99；UI / raster / build→raster 排队三段）+ build/paint 计数（**build ≠ paint**）+「N 帧 0 构建 / paint 计数不变」headless 回归测试；空闲零开销 | D1 |
| **P-R（Retained 化）** | **部分✅（D2a，2026-11-03）**：整层档稳态烘焙已实现（稳态每帧只贴图 + 激活行，整层高斯 saveLayer 移除；**缓存与位置无关**，换行/滚动不重烘焙、过渡帧也复用贴图、烘焙摊帧预取；`lyrics_physics_wall_bake.dart`）。**观感有变化**（旧链含引擎伪影、实际 ~3× 过模糊 → 干净 σ4），发版需注明。剩余：逐行档烘焙、逐行 Retained 化（ValueListenable 直连变换）视 P0 真机实测决定 | D2/D4 |
| **P-Mask（封面渗入烘焙）** | 全屏封面「图片 + 右缘遮罩」一次性烘焙成 `ui.Image`（与背景模糊同一套：物理分辨率长边封顶 2048、封面/尺寸变化时重烘、失败回退 `ShaderMask`），去掉每帧封面面板面积的离屏层；先用 `ARCHOERA_COVER_MASK=off` 测占比（§4.2d） | D4 |
| **P-G（玻璃共享输入）** | **✅（2026-11-03）**：`GlassBlur.backdropIsBakedBlur`——背后只有预烘焙模糊背景的面板免 `BackdropFilter`（共享背景那次高斯）；落点为停靠播放条（内容层已让位、无动态内容穿过）。其余玻璃面背后有动态内容，保留真模糊 | D3 |
| **P-Cover（封面限流）** | 列表封面解码并发上限 ~2 的队列调度，平滑冷启动尖峰 | D5 |
| **纪律修正** | 「包 `RepaintBoundary` = 已缓存」在 Impeller GLES 下不成立（raster cache 关闭）；需缓存处一律显式栅格化（预烘焙已对齐） | D1（§3.1） |

---

## 6. 验收与测试

- **性能**：目标机含 **iGPU**（Intel UHD/Iris、AMD Vega、Apple 集显）与软件渲染（llvmpipe）；
  全屏播放页在 60Hz 达帧预算、条件允许时 120Hz；用 Timeline 帧时间而非肉眼。
- **内存**：歌词相关常驻峰值符合 §3.4 预算（DevTools Memory 实测）。
- **正确性**：涟漪随机序列/生命周期/速度与上游一致；歌词高亮/锚点/seek 行为不回退（复用
  `test/amll_physics_wall_test.dart`、`test/lyrics_view_test.dart`）。
- **回退**：`FragmentProgram` 不可用 / 软渲染时功能与观感可用。
- **跨端**：Linux / Windows / macOS 三端视觉一致；Windows 注意 Impeller/ANGLE 后端差异与老 iGPU 驱动。
- **CI**：`dart analyze lib` 0 issue、`flutter test` 全绿（既有网络/凭据用例除外）。

### 6.1 P1–P3 测量方法（决定是否做 P4 / P2b）

1. 用 **profile/release 包**运行（`flutter run --profile` 或已打包产物）；全屏播放页、2K/4K、
   120Hz（若有）。
2. DevTools **Performance**：分别记录 **UI 线程**与 **raster 线程**帧时间：
   - UI 高 → 歌词/水纹 CPU（看 P1 是否够）；
   - raster 高 → 填充率/模糊（看 P2/P3 是否够）。
3. **A/B 对照**（设置 → 播放）：
   - 背景 `ripple`（GPU shader）↔ `blur`/`solid`（无 shader）比 raster；
   - 开关 `performanceMode`；歌词引擎 `amll` ↔ `simple`；频谱开/关。
4. GPU 占用：Windows 任务管理器（辅以 PresentMon/GPUView）；Linux 用 `intel_gpu_top`/`radeontop`。
5. 内存：DevTools **Memory**，看歌词段落缓存常驻是否随视口有界、切歌后回落（§3.4）。
6. 结论分派：
   - 歌词 UI 仍高 → 做 **P4**（逐字符图集，变体 A）；
   - raster 仍高（iGPU）→ 做 **P2b 半分辨率**；
   - 均达标 → 直接 **P5 自适应画质**收尾。

---

## 7. 非目标

- 不手写跨平台渲染框架；不改 Flutter/Impeller 引擎。
- 不为整屏 UI 引入 FFI + 原生 GPU（Vulkan/Metal/D3D）通道——除非某单一特效用着色器确实做不到。
- 不追求独显专属效果；不以「上独显才流畅」为前提。

---

## 8. 开放问题（待定）

1. ~~是否新增 `player.effectQuality` 偏好~~ → 移交 [runtime-resource-optimization.md](runtime-resource-optimization.md) §8.4。
2. ~~背景 `blur` 档是否并入 ripple~~ → **已定**：`ripple` 叠在模糊封面（`_BlurredCover`）之上，
   与 `blur` 档共用基座（`player_background.dart`，2026-09-16）。
3. 歌词后处理（glow/blur）是否在 P4 之后才评估？
4. iGPU 目标基线机型/分辨率/刷新率清单（用于 P0/R0 基线）。
5. ~~帧时间自适应降级是否做成全局服务~~ → 移交 [runtime-resource-optimization.md](runtime-resource-optimization.md) §4.5。
