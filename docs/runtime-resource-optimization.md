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

## 3. 跨框架机制调研（源码级，提炼可迁移项）

> **调研基线（2026-09-16 本地浅克隆）**：
> - Qt：`qtdeclarative` commit `3027a40c`（dev，Qt 6.x）— 下文路径省略前缀 `src/quick/scenegraph/`
>   （item 层为 `src/quick/items/`）。
> - Chromium：`chromium/src` commit `823ae20f`（main）— 下文路径省略前缀 `cc/`。
> - 复现：`git clone --depth 1 https://github.com/qt/qtdeclarative`；
>   `git clone --depth 1 --filter=blob:none --sparse https://chromium.googlesource.com/chromium/src && git -C src sparse-checkout set cc`。

### 3.1 Chromium / Electron（`cc` 合成器，源码精读）

**分块（tiling）与尺寸策略**
- GPU 光栅瓦片≈**视口高度 / 4**，随内容宽度缩小收窄到 2、1：`layers/tile_size_calculator.cc:67-85`。
- 再夹到 `max_gpu_raster_tile_size` 与最小高度 **256px**：`tile_size_calculator.cc:54-58`、
  `trees/layer_tree_settings.h:94`。
- 软件/未分块默认 **256×256**，**< 512² 的小层不分块**（这是小层的关键省法）：
  `trees/layer_tree_settings.cc:17-18`。
- 每块**边距 1 texel**（`tiles/picture_layer_tiling.h:78`、`base/tiling_data.cc:172-228`），
  尺寸**向上对齐 32/64**（`tile_size_calculator.cc:19-27,51-52`）——避免接缝并利于纹理对齐。

**部分光栅 / 只更新损伤区**
- 失效区域→瓦片重映射（含边距），旧瓦片带 `invalid_content_rect` 复用：
  `tiles/picture_layer_tiling.cc:278-328`、`tiles/tile.h:137-145`。
- **只回放脏像素**：旧资源 ∩ 脏矩形，仅栅格化变化部分：`tiles/tile_manager.cc:1509-1516`、
  `raster/one_copy_raster_buffer_provider.cc:266-272`；`raster/raster_source.cc:86-117`。
  默认 `use_partial_raster=false`，且需 `msaa_sample_count==0`：`trees/layer_tree_settings.h:112`、
  `tile_manager.cc:2116-2122`。
- 优先级 `NOW / SOON / EVENTUALLY` + 到可视区距离；被遮挡瓦片降级而非不处理：
  `tiles/tile_priority.h:36-57`、`tiles/picture_layer_tiling.cc:768-828`。
- 每帧调度上限 **32** 个栅格任务：`tile_manager.cc:1006-1011`、`layer_tree_settings.h:120`。
- 远景（> `max_preraster_distance=1000px`）**只解码图片、不栅格**：
  `picture_layer_tiling.cc:737-741`、`layer_tree_settings.h:128`。

**内存上限与回收**
- 默认策略 **64 MiB**：`trees/layer_tree_settings.cc:22-24`；硬/软限拆分：
  `trees/layer_tree_host_impl.cc:1806-1826`。
- `AssignGpuMemoryToTiles`：NOW 用硬限、其余用软限，逐级按优先级驱逐；
  `NOW` 放不下时报“limits exceeded”：`tile_manager.cc:912-1092`。
- 空闲 **5 分钟**回收低于可见-NOW 优先级的瓦片：`tile_manager.h:388`、`tile_manager.cc:495-517`；
  `TrimPrepaintTiles` 清 `> SOON`：`tile_manager.cc:520-580`。

**遮挡裁剪（occlusion culling）**
- 遍历 effect-tree，只有**不透明、轴对齐、非 mask** 的层才遮挡；小矩形（< **160×160**）跳过跟踪：
  `trees/occlusion_tracker.cc:129-226,357-411`；`trees/layer_tree_settings.cc:19`、
  `trees/layer_tree_impl.cc:1886-1889`。
- 遮挡写回各层 `occlusion_in_content_space`（`layer_tree_impl.cc:1891-1931`），
  参与瓦片优先级默认**关**（`layer_tree_settings.h:121`、`layers/picture_layer_impl.cc:429-440`）。

**图层化 / 不透明快路径**
- `will-change` → `raster_even_if_not_drawn`（离屏也预栅格）：`trees/property_tree.cc:977-982`、
  `trees/draw_property_utils.cc:1190-1200`。
- **每个 render surface 一个 FBO**；提升原因枚举在 `trees/effect_node.h:34-64`（opacity/filter/
  backdrop/mask/clipPath/blend/copy 等），`HasRenderSurface()` `:224-226`。
- `SetContentsOpaque` → 免整层透明 clear、只清边距：`layers/layer.cc:894-900`、
  `layers/picture_layer.cc:123`、`raster/raster_source.cc:87-102`。
- filter 会**扩张离屏**并保守清遮挡：`paint/filter_operations.cc:63-86,120`。

**批处理 / paint op**
- op 存在单一 `PaintOpBuffer`，`DisplayItemList::Finalize` 建 **rtree 空间索引**，
  回放只取与目标矩形相交的 op：`paint/paint_op_buffer.h:167,328`、`paint/display_item_list.cc:85-125,200-213`。
- **纯色瓦片直接跳过栅格**：≤ `kMaxOpsToAnalyze=5` 个 op 时分析为纯色即不画：
  `tile_manager.cc:65,950-976`、`paint/solid_color_analyzer.cc:294,327,335`。

**图片解码缓存（对我们的封面/列表最直接）**
- 预算默认 **128 MiB**、低端 **32 MiB**、RAM ≥ 4 GiB 时 **256 MiB**：
  `tiles/image_decode_cache_utils.cc:20-38`。
- **按目标尺寸 + mip 解码**：`software_image_decode_cache.cc:118-140,400-410`、
  `gpu_image_decode_cache.cc:1581-1610`。
- 工作集上限 **256 items**（`gpu_image_decode_cache.cc:68-75`），LRU 驱逐（`:1839-1881`），
  持久缓存上限 2000/挂起 0（`:917-918`）。
- 内存压力：`SetShouldAggressivelyFreeResources(true) → EnsureCapacity(0)`（`:1247-1270`），
  30s 过期清理（`:1388-1417`）；GPU 条目**不保留** CPU 像素（`:1780`）。
- **可丢弃内存**：解码像素 `Unlock()` 交 OS 回收：`tiles/software_image_decode_cache_utils.cc:68-88,165`、
  `gpu_image_decode_cache.cc:1985-1988`。

**节流 / 调度**
- 单帧提交上限 `kMaxPendingSubmitFrames=1`：`scheduler/scheduler_state_machine.cc:34,1497-1503`。
- 主帧限制到 ~60Hz（slack 0.9）：`scheduler_state_machine.cc:36,50-76,1481-1494`。
- 连续无损伤 commit 后 ×2 节流：`proxy_common.cc:22-59`。

### 3.2 Qt Quick（Scene Graph + RHI，源码精读）

**图层 / 离屏 FBO 缓存**
- **脏标志驱动**：`QSGRhiLayer::updateTexture()` 仅在 `(m_live||m_grab) && m_dirtyTexture` 时抓取，
  抓取后清标志 → **内容未变不重渲**：`qsgrhilayer.cpp:68-81,411-414`。
- RT 仅在像素尺寸/格式/递归/mipmap/MSAA 变化时重建：`qsgrhilayer.cpp:261-265`；
  格式 `RGBA8/RGBA16F/RGBA32F`（`:138-161`），mipmap 每次抓取都 `generateMips`（贵）：`:274-276,484-489`。
- `layer.enabled` 实际是 `QQuickShaderEffectSource`（hideSource）；默认 `live=true, mipmap=false,
  smooth=false, RGBA8`：`src/quick/items/qquickitem.cpp:9937-9964,9869-9883`。

**只更新损伤区（增量重建）**
- RHI 路径**没有** damage-rect；改为「脏子树重建 + 批次复用」：重建位
  `FullRebuild|BuildRenderLists|BuildBatches`（`coreapi/qsgbatchrenderer.cpp:870-872`），
  按 batch root 局部重建（`:1632-1682`），有 order 预算，溢出则整表重建（`:570-587`）。
- 几何/材质变化能复用 batch 才 `needsUpload`，否则失效：`:1464-1487`；
  仅 dirty item 同步：`src/quick/items/qquickwindow.cpp:2151-2168`。
- **软件后端有真正的 dirty region**（可对照）：`adaptations/software/qsgsoftwarerenderer.cpp:26-32`。

**合批（batching）**
- 不透明判据：`inheritedOpacity > 0.999` 且非混合材质且有深度缓冲（`OPAQUE_LIMIT`）：
  `qsgbatchrenderer.cpp:80,1545-1549`；不透明**前→后**、透明**后→前**排序：`:3828-3841`。
- 合并键：同 root / clipList / drawingMode / attributes / 材质 type/compare / 继承不透明度等：
  `:1800-1811,1917-1930`；**透明重叠保护**（重叠即停止合并）：`:1823-1838,1891-1946`。
- 自动批根阈值 64 个可渲染节点 / 1024 顶点；VBO/IBO 池上限 2 MB：
  `:1440-1447,913-914,89,1029-1035`。

**字形 / 纹理图集**
- SDF 图集：`RED_OR_ALPHA8`、**padding=2**、最多 **3** 张 `TextureSizeMax`；分配失败按
  **未使用 LRU 逐出**：`qsgrhidistancefieldglyphcache.cpp:19-21,47-58,60-86,273-278`。
- 曲线字形：按 **base font size=64** 生成网格一次，运行时按 `pixelSize/fontSize` 缩放复用：
  `qsgcurveglyphatlas.cpp:16-26,120-142`。
- 图像图集：起始 `max(512,nextPow2)`、每项 **pad +2**、超过 `max(w,h)/2` 走独立纹理：
  `util/qsgrhiatlastexture.cpp:39-51,83,192,153-158`、`util/qsgareaallocator.cpp:22`。

**裁剪（clip）**
- 矩形轴对齐 → **scissor**，只有非矩形/旋转才用 **stencil**：
  `coreapi/qsgnode.cpp:1097-1103`、`qsgbatchrenderer.cpp:2440-2479`（scissor）vs `:2480-2642`（stencil）。
- stencil 每帧聚合一次、跨批复用；**clipList 不同则不合并**：`:2410-2414,2616-2621,2653-2660,1800,1917`。

**遮挡 / 不可见跳过**
- 不透明度 < **0.001** 阻断整棵子树：`coreapi/qsgnode.cpp:1329,1394-1397`、
  `qsgbatchrenderer.cpp:1398-1413,1533-1534`。
- `visible=false` → opacity 归零（`qquickwindow.cpp:2393-2418`）；ListView/GridView 视口外
  `setVisible(false)`（`qquicklistview.cpp:908`、`qquickgridview.cpp:630-640`）；
  `ItemObservesViewport` 让 item 按窗口视口裁剪（`qquickitem.h:141-142`）。

**渲染循环 / 空闲**
- Qt 6 **已无 `RenderPolicy`**（Qt5 API 移除）；`QSG_RENDER_LOOP` 仅 `basic|threaded`：
  `qsgrenderloop.cpp:226-235`。
- 线程在无更新时睡眠：`qsgthreadedrenderloop.cpp:993-998`；Qt 6 **暴露即出帧**（与 Qt5 不同）：`:730-738`。
- vsync 驱动动画、坏 vsync 检测（20 样本）：`:1124-1138,1583-1607`；`QSG_NO_VSYNC`：
  `qsgdefaultcontext.cpp:191-205`。

### 3.3 WebRender（Servo / Firefox，文档级，未拉源码）

- **保留式显示列表（display list）** + **picture caching**：把「内容切片」缓存为纹理，
  仅滚动/变换时不重录。
- **clip / scroll 节点**与**内容无关的合成**；GPU 批次 + **纹理图集（atlas）**。
- （源码精读留待需要时再补：`webrender/src/`。）

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

### 3.5 可迁移机制清单（附源码出处）

| 机制 | 源码出处 | 我们对应的落点 |
|---|---|---|
| 图层缓存 / FBO 复用（脏标志驱动） | Qt `qsgrhilayer.cpp:68-81,411-414`；`cc` `effect_node.h:224-226` | 背景**静态层**、播放条、侧边栏包 `RepaintBoundary` |
| 只更新损伤区 | `cc` `picture_layer_tiling.cc:278-328`、`tile_manager.cc:1509-1516`；Qt `qsgbatchrenderer.cpp:1632-1682` | 水纹**动态层**只画活动涟漪 |
| 降分辨率 / LOD | `cc` `tile_size_calculator.cc:67-85`；Qt `qsgcurveglyphatlas.cpp:120-142` | 动态层低分辨率离屏、静态层 1/2~1/4 预烘焙 |
| 内存上限 + 优先级回收 | `cc` `tile_manager.cc:912-1092,495-517`；`layer_tree_settings.cc:22-24` | 图片/图层缓存上限、空闲回收 |
| 遮挡裁剪 / 不可见即停 | `cc` `occlusion_tracker.cc:129-226`；Qt `qsgnode.cpp:1329`、`qsgbatchrenderer.cpp:1533` | `Offstage`/`Visibility` + `TickerMode`（已有，扩展） |
| 批处理 / 图集 | Qt `qsgbatchrenderer.cpp:1800-1946`、`qsgrhiatlastexture.cpp`；Skia `drawAtlas` | 频谱单 Path（已 P3）→ 评估 `drawAtlas`；歌词字形缓存 |
| 裁剪的代价（scissor > stencil，且破坏合批） | Qt `qsgbatchrenderer.cpp:2440-2479,1800` | 减少 `Clip*`/`saveLayer`，列表 delegate 内禁止 |
| 不透明快路径 | `cc` `layer.cc:894-900`、`raster_source.cc:87-102`；Qt `qsgbatchrenderer.cpp:1545-1549` | 避免无谓半透明/模糊叠层 |
| 图片按显示尺寸解码 + 解码缓存上限 | `cc` `image_decode_cache_utils.cc:20-38`、`software_image_decode_cache.cc:118-140` | 沿用 `CoverImage` `cacheWidth/Height` + `ImageCache` 上限 |
| 生命周期 / Loader | Qt `Loader`+`destroy()`（文档）；`cc` discardable | 页面分支卸载、模块注册表、图片缓存上限 |
| 后台节流（连 ticker 一起停） | `cc` `scheduler_state_machine.cc:1481-1503`；Qt `qsgthreadedrenderloop.cpp:993-998` | `power_saver.dart` + `FrameGovernor` |

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

**源码给出的具体形状（照抄机制，不照搬规模）**：
- `cc` 的「只回放脏像素」= 旧资源 ∩ 脏矩形（`tile_manager.cc:1509-1516`）——我们只需
  **每个涟漪的波带包围盒作为脏矩形**，与上一帧合并后只在该区域重画动态层。
- **警惕**：`cc` 的 partial raster **默认关闭**（`layer_tree_settings.h:112`，且要求无 MSAA），
  说明「损伤区」不是无脑收益——我们要用**小规模实验**验证（见 §8.1），而不是默认全上。
- 「降分辨率」在 `cc` 是**视口/4** 的瓦片（`tile_size_calculator.cc:67-85`），并非全屏半分辨率；
  我们不一定要固定 1/2，可按设备帧时间**自适应**（§4.5）。
- 小层可**不分块**（< 512²，`layer_tree_settings.cc:17-18`）——对应我们的「频谱/歌词区不解锁额外层」。

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
- **裁剪优先矩形（scissor 而非 stencil）**：能用轴对齐矩形裁剪就别用圆角/旋转裁剪——
  Qt 对矩形 clip 走 scissor、非矩形才落到 stencil（`qsgbatchrenderer.cpp:2440-2479` vs `:2480-2642`），
  且 **clipList 不同即无法合批**（`:1800,1917`）。Flutter 侧 `ClipRect` 比 `ClipRRect` 更易合批。
- **不透明快路径**：`cc` 对不透明层免整层 clear、只清边距（`raster_source.cc:87-102`）；
  Flutter 侧表现为「避免无谓 `saveLayer`/半透明叠层」，让不透明子树可被合批/裁剪。
- **避免大层上的 opacity/filter/backdrop 动画**：这些会把层提升为独立 render surface/FBO
  （`cc` `effect_node.h:34-64`），是 overdraw 与显存来源；动画尽量落在小层或并入着色器。
- **遮挡即不画**：被不透明层盖住或不可见的内容 `Visibility(visible:false)` 或 `Offstage`，
  不要用「透明」硬画；小区域可忽略（`cc` 最小遮挡跟踪 160×160，`layer_tree_settings.cc:19`）。
- **图片预算**：沿用 `CoverImage` 的按显示尺寸解码；补 `PaintingBinding.imageCache` 上限
  与「路由退出 evict」。对照 `cc`：解码缓存默认 128 MiB（低端 32 / ≥4 GiB 256，
  `image_decode_cache_utils.cc:20-38`），按目标尺寸 + mip 解码，内存压力直接释放
  （`gpu_image_decode_cache.cc:1247-1270`）。Flutter 的 `ImageCache`（`maximumSizeBytes`）
  可设同类上限并在低内存时 `evict`/`clear`。

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
6. **损伤区粒度**：按「每个活动涟漪的波带包围盒」逐个 dirty rect，还是整个动态层半分辨率刷新？
   （参考：`cc` 的 partial raster **默认关闭**，`layer_tree_settings.h:112`；需小实验权衡。）
7. **缓存回收策略**：是否照 `cc` 引入「字节上限 + 优先级 + 空闲回收」（`tile_manager.cc:912-1092,495-517`），
   还是保持 Flutter `ImageCache` + 分支卸载的轻量组合即可？

---

## 9. 关联文档与参考

- [player-render-optimization.md](player-render-optimization.md) — 播放页三引擎专项（背景/歌词/频谱）
- [module-on-demand-load-plan.md](module-on-demand-load-plan.md) — 原生模块按需加载与释放
- [architecture.md](architecture.md)、[benchmark-2026-09-10.md](benchmark-2026-09-10.md)、
  [test-suite-2026-09-10.md](test-suite-2026-09-10.md)
- 上游实现：`SPlayer-Next/src/components/player/FullPlayer/PlayerBackground.vue`、
  `.../BackgroundRipple.vue`
- 外部机制参考：
  - **源码级（本地克隆精读，§3.1–3.2）**：Qt `qtdeclarative@3027a40c`（dev）、
    Chromium `chromium/src@823ae20f`（main，仅 `cc/`）；克隆命令见 §3 引言。
  - Qt Quick Scene Graph / Performance 文档：`doc.qt.io/qt-6/qtquick-visualcanvas-scenegraph.html`、
    `doc.qt.io/qt-6/qtquick-performance.html`（batching、preprocess/LOD、`QSGLayer`、
    「clip 不是优化」、不可见即不画、`sourceSize`、Loader/destroy、粒子不可见即停）。
  - WebRender（文档级）：保留显示列表 + picture caching + atlas。
  - Flutter/Impeller：`RepaintBoundary` 层缓存、`FragmentProgram`、
    `ImageFilter.shader`（仅 Impeller，`painting.dart:4461`）、Skia `drawAtlas`。
