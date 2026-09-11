# 播放页渲染优化专项（Player Render Optimization）

> 状态：**进行中（2026-09-11）**——P1（歌词缓存）、P3（频谱批处理）**已实现**；
> P2 背景：封面预烘焙 + CPU 网格已优化并生效，**全分辨率 GLSL 因集显扛不住默认关闭**
> （待 P2b 低分辨率离屏后重开）；P4 字形图集 / P5 自适应画质规划中。
> 目标：消除**全屏播放页**在高刷新率 / 大面积渲染下的卡顿，并以
> **集成显卡（iGPU）为基线**（独显只作上限，不作前提）。
> 范围：播放页三块渲染重件——**高级歌词 / 背景 / 频谱**；不含列表页、设置页。
> 关联：
> [architecture.md](architecture.md)、
> [CROSS_PLATFORM_CAPABILITY_IMPROVEMENT.md](CROSS_PLATFORM_CAPABILITY_IMPROVEMENT.md)。

---

## 0. TL;DR

- 卡顿集中在**全屏播放页**，是「三块独立引擎 + 大面积画布」叠加的结果，**不是 Flutter/Impeller 引擎的问题**。
- 三块瓶颈**性质不同，必须分开优化**，不要指望一个 GLSL 方案通吃：

  | 模块 | 真正瓶颈 | 主手段 | GLSL 定位 |
  |---|---|---|---|
  | 背景（水纹/模糊） | 逐像素填充率 + CPU 顶点场 | **片元着色器** | 主解 |
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
| 背景 | `player_background.dart` + `ripple_background.dart` | 活跃 | 4 档：gradient/blur/solid/ripple |
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
- **P2b（重开着色器的前提）**：必须先做**低分辨率（1/2~1/6）离屏降采样**再放大，
  否则集显扛不住；届时再评估是否重开 `kEnableRippleShader`。

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

### 4.3 频谱 → 批处理（P3 已实现）

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
- 统一自适应画质控制器（帧时间滑动窗口 → 档位）。

---

## 5. 阶段计划（可验收）

| 阶段 | 内容 | 验收 |
|---|---|---|
| **P0** | profile 基线：全屏 2K/4K、120Hz，记录 UI/raster 线程帧时间 | 产出基线与瓶颈归属报告 |
| **P1 ✅** | 歌词：Paragraph 缓存（可见窗口）+ 去 `saveLayer` | 全屏歌词区 UI 线程帧时间显著下降；歌词回归测试全绿；常驻内存符合 §3.4 |
| **P2 ✅** | 背景：`FragmentProgram`（单 pass + 封面模糊预烘焙；CPU 仅失败兜底） | 着色器四后端（SKSL/GLES3/Vulkan/Metal）编译通过；CPU 回退可用；三端视觉/帧时间待真机 |
| **P2b** | 半分辨率离屏降采样（仅当实测 iGPU 仍不足） | 帧时间进一步下降、视觉可接受 |
| **P3 ✅** | 频谱：单 Path 批量 + 渐隐并入画笔 | 无 `ShaderMask` 离屏层；三样式冒烟测试绿 |
| **P4** | 逐字符精灵图集（公开 API 限制，见 §4.2；待 P1–P3 实测后定） | 歌词区 UI 线程≈常数（与行数弱相关） |
| **P5** | 自适应画质 + 档位 | iGPU 机器稳定达帧预算；无独显依赖 |

> 顺序原则：**先 P1（收益最大且不依赖渲染后端）→ 再 P2**；P3 随时可插；P4/P5 视 P1/P2 后剩余瓶颈决定。

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

1. 是否新增 `player.effectQuality` 偏好（性能/均衡/画质/自动），还是复用 `performanceMode` 二档？
2. 背景 `blur` 档是否统一并入 ripple shader 的单 pass，还是保留独立实现？
3. 歌词后处理（glow/blur）是否在 P4 之后才评估？
4. iGPU 目标基线机型/分辨率/刷新率清单（用于 P0 基线）。
5. 是否把「帧时间自适应降级」做成全局服务，供列表页等复用。
