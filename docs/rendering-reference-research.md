# 渲染优化参考调研（外部合成器项目）

> 状态：**调研完成（2026-11-03），未实施**——结论供 P0 测量补全与后续候选项参考。
> 参考项目为某 **Flutter 原生 Wayland 合成器**（Rust + Smithay 底座，内嵌 Flutter
> Engine；GPL-3.0-or-later）。项目名称与出处见
> [acknowledgements.md](acknowledgements.md) 「特别鸣谢」；本机参考克隆**不入库**。
> 关联：
> [player-render-optimization.md](player-render-optimization.md)、
> [runtime-resource-optimization.md](runtime-resource-optimization.md)、
> [licensing.md](licensing.md)。

---

## 0. TL;DR

- 该项目把「**低且稳定的帧时间**」当一等工程目标，其 Flutter 侧优化与我们的痛点
  （填充率 / 离屏层 / 每帧重建）高度同源，且多条实测结论与我们的基准**独立互证**。
- **许可证红线（必须遵守）**：参考项目为 **GPL-3.0-or-later**，我们为
  AGPL-3.0-or-later。本调研**只借鉴思想、方法与实测结论**；**禁止逐行/逐段移植
  其代码**，**禁止照搬其标识符命名**（与 `CONTRIBUTING.md`「命名原创」一致）；
  落地实现一律自研重写，引用其结论时注明「思路源自外部合成器参考项目」即可。
  文档/模块命名**不出现参考项目名称**（用户要求，2026-11-03）。
- 最有价值的四条：**① Impeller GLES 下 raster cache 关闭，缓存必须显式栅格化**；
  **② 动画收敛到 render object（Retained 化），每帧 0 build / 0 layout**；
  **③ 模糊成本 = 离屏层数 × 像素量，σ 几乎无关**（与我们 §4.2.1 实测一致）；
  **④ 渲染审计 + 「N 帧 0 构建」headless 回归测试方法论**。
- 合成器本体技术（direct scanout、GBM/DMA-BUF、引擎 fork）**不适用**，别走弯路。

---

## 1. 参考对象概览

该参考项目 = Rust + Smithay 合成器底座 + 通过 Embedder API 直接嵌入的 Flutter
Engine（AOT Dart shell）。Flutter 不是跑在别人的合成器里的应用，而是「就是桌面」：
Impeller 直接渲进合成器拥有的 KMS 缓冲区，无二次合成 pass。关键文档
（参考克隆内路径）：

- `docs/architecture.md` —— 运行时边界与帧路径；
- `docs/MOBILE_RENDERING_OPTIMIZATION.md` —— 移动端（Moto Edge 70）渲染优化实录；
- `docs/RENDER_AUDIT.md` —— 渲染审计指标与缓存分层设计；
- `docs/research/MOBILE_GLASS_OPTIMIZATION_PROPOSAL.md` —— 玻璃/模糊成本提案；
- 其 Flutter SDK 包 `lib/src/widgets/` —— 可借鉴的 Dart 层手法。

## 2. 许可证边界（硬约束）

| 事项 | 结论 |
|---|---|
| 参考项目许可证 | GPL-3.0-or-later（其仓库 README/LICENSES） |
| 本项目许可证 | AGPL-3.0-or-later（`docs/licensing.md`） |
| 是否可抄代码 | **否**。用户明确要求（2026-11-03）：不直接抄代码；只借鉴思路与方法 |
| 是否可借鉴思想 | **是**。软件的「方法/算法/实测结论」不受版权保护；落地实现必须自研重写 |
| 标识符命名 | 禁止照搬（其 `Retained*` 等命名不得复用；`CONTRIBUTING.md` §4「命名原创」） |
| 本仓命名 | 文档/代码/模块**不以参考项目命名**；名称仅出现在 `acknowledgements.md` 鸣谢条目 |
| 出处标注 | 注释/文档可写「思路参考外部合成器项目（GPL-3.0），自研实现」，不贴其源码 |

> 自研实现的判定基准：不看其源码逐行写；依据本调研文档记录的**行为描述与结论**实现，
> 实现细节（类名、结构、API 形态）均为本项目自有。

## 3. 核心实测结论（独立互证 + 新知）

### 3.1 Impeller GLES 下 raster cache 是摆设（重要新知）

参考项目在其 pinned engine 上实测：`GPUSurfaceGLImpeller::EnableRasterCache` 返回
**false**——`RepaintBoundary` + `isComplex/willChange` 只能保住 widget/layer 树身份，
**矢量绘制（SVG、Path、渐变）每帧照样重放**（其优化实录 §Shared SVG app icons）。

- 推论：凡指望「Flutter 会帮我缓存」的图层策略，在 Impeller GLES 上不可靠；
  需要缓存的地方必须**显式栅格化**（栅格成 `ui.Image` 当普通纹理画）。
- 对我们：背景封面的「模糊预烘焙成 `ui.Image`」（`blurred_cover.dart`）正是这条路，
  被参考项目独立验证。但需排查项目里其它「包个 `RepaintBoundary` 就当已缓存」的
  假设——特别是含矢量绘制的静态装饰。

### 3.2 模糊成本模型：层数 × 像素量，σ 几乎无关（互证）

参考项目玻璃提案（`MOBILE_GLASS_OPTIMIZATION_PROPOSAL.md`）与我们
`player-render-optimization.md` §4.2.1 的基准**结论一致**：

1. 成本由**离屏层数 × 模糊像素量**主导，高斯半径 σ 影响很小（我们：16.2 vs 16.5 ms；
   他们亦发现 σ 调整「几乎免费」）；
2. 「整层一次」只有在**降采样**后才比逐层便宜（我们：整层 @1/4 赢，@1/1 反而更贵）；
3. 其第三方案「运动时临时降模糊分辨率、静止后恢复」与我们 LyricsBlurBudget 的
   latch 降级思路同构。

新增洞察（我们没有的）：

4. **共享模糊输入**：同屏多个玻璃面各自 `BackdropFilter` = 对下层各自做一次全量
   采样 + 高斯，是重复劳动。应把「下层合成 + 高斯」一次算完，各面板只对结果
   做形状/色调（其方案 1「共享模糊输入」）；
5. **收紧滤波取样区**：引擎可能按矩形包围盒对滤波区取样，小暴露面配大包围盒
   是白烧（其方案 2）。

### 3.3 连续运动与结构状态分离（重要方法论）

其优化实录 §Dart mobile scene work 的总纲：

> 区分**连续运动**（progress/translation/scale——不改变内容）与**结构状态**
> （改变内容的状态）；连续运动留在 render 边界，结构状态才走 widget 重建。

落地手法（其 SDK 包的 translation/scale/window-motion 三个 retained 渲染对象，
仅借鉴行为，不复用代码）：

- 动画进度以 `ValueListenable` 直连自定义 `RenderObject`（如 `RenderTransform`
  子类），监听器里只更新矩阵——**每帧 0 widget build、0 layout**；
- 位移按物理像素 snap（`dx * dpr` 四舍五入再除回），避免 retained 纹理脱离像素网格；
- 几何插值每次 paint 只求值一次；命中测试跟随同一变换；
- 子树保持挂载：隐藏时停 ticker、释放输入焦点，而不是卸载重建；
- 配套回归测试 = headless 断言「60 帧动画 0 次 widget build / paint 计数不变」。

### 3.4 分层隔离：静态件必须与「永不被缓存的东西」分家

其渲染审计文档 §Cache candidate：桌面窗口帧拆三个兄弟节点——① 静态阴影/边框
（独立 `RepaintBoundary`）；② 活的外部纹理；③ 廉价的状态边框。原因：
**含外部纹理（`TextureLayer`）的子树永远不会被 raster cache 接纳**，混在一起会把
静态件的缓存键一起作废。

- 对我们：视频/频谱/每帧 repaint 的层同理——近静态件（封面、背景、控制栏）必须
  与每帧变的层（歌词、频谱）**兄弟级隔离**，不能包进同一个子树。

### 3.5 遮挡剔除（compositor 级，Dart 层只能近似）

其渲染审计文档：完全被上层不透明层覆盖的层**不参与采样**，其缓冲也不再等待。
与 `runtime-resource-optimization.md` §3.11 的结论一致：Flutter 引擎侧不会替我们
做这件事，只能 `Offstage`/`Visibility`/`TickerMode` 显式隐藏，或布局上避免
被完全盖住的大面积层照常重画。

### 3.6 冷路径并发限流（小而实用）

其图标组件的加载调度器：**最多 2 个并发解码**，队列排空驱动；防止一屏新内容
（如启动器首帧）同时涌出几十个 isolate/codec 任务打爆低端 CPU。图片缓存本身仍
负责去重，限流只平滑冷启动尖峰。

### 3.7 渲染审计与「零构建」回归测试方法论（补 P0 的蓝本）

其渲染审计文档的指标分组与纪律，值得整套方法论移植（自研实现）：

- **build ≠ paint**：两个计数分开上报；
- `FrameTiming` 按 avg/p50/p95/p99/max 分组，**UI 线程、raster 线程、build→raster
  排队延迟**三段分开——与我们 §1.3「必须区分线程」同构，但它给出了现成的字段模板；
- 每秒聚合、空闲零开销（审计关闭时不建任何计时器/缓冲）；
- 明确警告：**paint-only 路径的瓶颈可能是填充率/纹理带宽，不能从 build 计数下结论，
  必须真机 trace**；
- 回归测试形态：headless `flutter test` 断言帧序列内的 build/paint 计数上界
  （如「1000 条快照 × 1200 次手势更新后，原始列表零重复读取」），验证的是
  **被消除的工作量**，不依赖真机帧时间。

### 3.8 （仅了解）引擎 fork 级优化——我们不做，但要知道它存在

GLES 后端在每个 draw 重复下发 viewport/scissor/program 状态；参考项目 fork 了
Flutter engine 在 pass 内缓存这三类状态。这解释了「Impeller GLES 上小 draw call
多了会莫名变贵」的现象，是我们**频谱/歌词控制 draw call 数**的又一佐证，但修复
本身在我们不可达（改引擎属非目标）。

---

## 4. 可迁移项清单（全部自研实现）

| # | 机制 | 参考项目出处（行为描述） | 我们的落点 | 优先级 |
|---|---|---|---|---|
| D1 | **测量补全**：FrameTiming 百分位分组 + build/paint 计数 + 「N 帧 0 构建」headless 回归 | 渲染审计文档 §Report sources、§3.3 回归形态 | `player-render-optimization.md` **P0**（**已落地 2026-11-03**：`frame_timing_stats.dart` + `build_paint_probe.dart` + `test/frame_probe_test.dart`；真机基线仍待） | **已落地** |
| D2 | **Retained 化**：连续运动收敛到 render object（ValueListenable → 自研 RenderObject）；以及「显式栅格化缓存」（静态内容烘焙成 `ui.Image`） | 其 SDK 包 retained 三件套（§3.3）；图标显式栅格（§3.1） | **部分落地（2026-11-03，D2a）**：歌词墙整层档稳态逐行烘焙（`lyrics_physics_wall_bake.dart`，稳态每帧只贴图 + 激活行）；逐行 Retained 化与精灵图集保留为候选，待 P0 真机实测 | 高（稳态烘焙已落地） |
| D3 | **玻璃共享模糊输入**：同屏多 `GlassBlur` 共享一次「下层合成 + 高斯」，面板只做形状/色调 | 玻璃提案 方案 1/2 | **已落地（2026-11-03）**：`GlassBlur.backdropIsBakedBlur`——停靠播放条复用壳层预烘焙模糊壁纸的那次高斯，免每帧整条离屏 pass（`player_bar_sections.dart`）；背后有动态内容的玻璃面（悬浮条/搜索下拉/队列面板/弹窗）保留真毛玻璃 | **已落地**（剩余收益待 P0 真机实测评估） |
| D4 | **显式栅格化纪律**：需要缓存的矢量/静态装饰显式栅格，不依赖 `RepaintBoundary` | 其图标组件（§3.1） | 排查项目内「包 `RepaintBoundary` 当缓存」的假设；封面/封面占位已走预烘焙 | 中 |
| D5 | **冷路径解码限流**：并发上限 2 的队列调度 | 其图标组件调度器（§3.6，仅借鉴行为） | 播放列表/歌手页封面滚动 | 低（小改动，独立） |
| D6 | **遮挡显式隐藏**：被完全覆盖的大面积层主动 `Offstage`/停表 | 渲染审计文档 §Multi-surface | **已落地（2026-11-03）**：`OffstageWhenComplete`——播放页完全展开后停绘壳层背景与停靠播放条（`opaque:false` 路由下仍被绘制的全屏浪费），保留状态、收起即恢复 | **已落地** |
| D7 | draw call 纪律（GLES 状态重复下发） | §3.8 | 已有 P3（频谱单 Path）；继续避免碎 draw | 已覆盖 |

> 每一项的验收方式见 `player-render-optimization.md` §6；D1 产出的测量基建是
> 其余各项的验收前提。

## 5. 不适用清单（防走弯路）

| 技术 | 为什么不适用 |
|---|---|
| 引擎 fork（GLES 状态缓存、外部纹理自主 damage、`TextureLayer::Diff` 修复） | 我们明确不改 Flutter/Impeller（`player-render-optimization.md` §7 非目标） |
| direct scanout / 硬件 overlay plane | 合成器专属能力，普通 app 不可达 |
| per-output GBM 缓冲池、DMA-BUF 零拷贝导入 | 合成器专属 |
| AOT 嵌入、FlatBuffers 控制协议 | 架构专属 |
| 引擎级 backdrop 缓存分组 | 依赖其 fork；Dart 层等价物就是 D3 的共享输入 + 层隔离 |

## 6. 后续动作

1. 本文档先入库存档（本文件，即本轮变更）。
2. `player-render-optimization.md` 补记 D1/D2/D3/D5 为新候选（见其 §5.1 补充段）。
3. `runtime-resource-optimization.md` §3.12 补录调研摘要与出处。
4. 实施顺序由 P0 实测决定；实施时逐项回到本文档核对许可证边界。
