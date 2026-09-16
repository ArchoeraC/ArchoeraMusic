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
- **范围不限于播放页**（用户 2026-09-16）：列表 / 首页 / 搜索 / 侧边栏 / 顶栏 / 播放条 /
  毛玻璃弹窗 / 路由转场 / 图片外观背景同样按四杠杆治理（见 §2.1、§4.6）。
- **实现边界硬约束**：只落 **Dart + 既有 FFI 桥接**、**集显优先且不依赖独显**、**不改引擎**
  （见 §1.2、§4.0、§7）。

---

## 1. 背景与目标

### 1.1 现象（用户 2026-09-16）
- 我们的**软件渲染要求**与**资源开销**相对上游 SPlayer-Next（Electron / Chromium）**高很多**。
- GPU 是其中最严重的一项：全屏播放页在集显（iGPU）上掉帧。

### 1.2 目标（可验收）
1. **iGPU 为默认目标**（硬约束）：Intel UHD/Iris、AMD Vega/APU、Apple 集显上全屏播放页
   达帧预算；软渲染（llvmpipe/SwiftShader）不崩、可降级。**多 GPU 机器默认走集显路径。**
2. **不得依赖 / 请求独显**（硬约束）：
   - 不导出 `NvOptimusEnablement`、`AmdPowerXpressRequestHighPerformance` 等
     「高功耗 GPU」标志，不做任何「诱导系统切独显」的事；
   - 不依赖独显专属能力（compute / storage buffer / 几何着色器 / 大 UBO / 高倍 MSAA）；
   - 不以「上独显才流畅」为前提——效果预算按集显设计，独显只是余量。
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

### 2.1 全应用 UI 面盘点（优化**不止播放页**）

| UI 面 | 现状 / 成本来源 | Dart 侧杠杆（§4.6） | 源码依据（§3） |
|---|---|---|---|
| 歌曲/专辑/歌手/歌单**列表** | 每项封面解码 + 圆角裁剪 + 阴影；滚动时 build/layout 大量离屏项 | `cacheWidth/cacheHeight` 按显示解码；`SliverFixedExtentList` + 小 `cacheExtent`；慎用 `ClipRRect`/阴影；`addRepaintBoundaries`/`addAutomaticKeepAlives` 取舍 | 3.7（`viewport.dart:289`、`sliver_fixed_extent_list.dart:410-494`、`scroll_delegate.dart:560-572`） |
| **首页 / 发现** | 大图背景 + 多个横向列表 + 频繁重建 | 分区 `RepaintBoundary`；横向列表同列表纪律；背景静态层 | 3.6 / 3.7 |
| **搜索页** | 输入联动全页重建 + 结果列表 | 去抖；列表复用；避免整页重绘（拆边界） | 3.7 |
| **侧边栏 / 顶栏 / 底部播放条** | 常驻；播放进度/封面频繁变化牵连重建 | 进度条/封面单独 `RepaintBoundary` 隔离；热路径避免 `AnnotatedRegionLayer` 等非保留层 | 3.7（`proxy_box.dart:4672-4683`） |
| **设置 / 弹窗 / 毛玻璃**（`glass_surface` 等） | `BackdropFilter` = 额外离屏 pass + 采样 backdrop | 限制范围、避免大层；单控件滤镜优先 `ImageFiltered`；不透明优先 | 3.4（`canvas.cc:1146-1520`）、3.7 |
| **路由转场** | 整页 clip/opacity/filter 动画 → 合成提升/离屏 | 性能模式直切（已有）；避免大范围 `Clip`/分数 `Opacity` 动画，改用位移/淡入小层 | 3.7（`proxy_box.dart:897-900`） |
| **图片外观背景**（`appearanceStyle=image`） | 全屏封面 + 模糊 | 静态层缓存 + 降采样（同背景主线） | 3.6 / 4.1 |
| **播放页**（背景/歌词/频谱） | 见专项文档 | 静态/动态分层、损坏区、批处理 | 3.3–3.9 |

> 全应用通用的四个杠杆与 §0 一致：**图层缓存 / 只画变化 / 降分辨率 / 不可见即停**。
> 列表与图片是除播放页之外**收益最大的两块**（解码内存 + 滚动帧时间）。

---

## 3. 跨框架机制调研（源码级，提炼可迁移项）

> **调研基线（2026-09-16 本地浅克隆）**：
> - Qt：`qtdeclarative` commit `3027a40c`（dev，Qt 6.x）— 路径省略前缀 `src/quick/scenegraph/`
>   （item 层为 `src/quick/items/`）。
> - Chromium：`chromium/src` commit `823ae20f`（main）— 路径省略前缀 `cc/`。
> - WebRender：`mozilla-firefox/firefox`（main）`gfx/wr/webrender/` — 路径省略前缀 `src/`。
> - Impeller：`flutter/engine` commit `ae5c3603`（main）— 路径省略前缀 `impeller/`。
> - Skia：`google/skia` commit `9875bb59`（main）— 路径含 `src/`。
> - **Flutter engine `flow/` + `lib/ui/`**：同 `flutter/engine` 仓库（光栅缓存 / 损伤区 / 图层）。
> - **Flutter framework**：`flutter/flutter` commit `3cdba02`（main）`packages/flutter/lib/src`。
> - **Dear ImGui**：`ocornut/imgui`（main）。
> - **Slint**：`slint-ui/slint`（main）`internal/`（脏区 / 部分渲染 / 项目缓存）。
> - （另已克隆 `zed-industries/zed` 的 `crates/gpui`，待需要时再精读。）
> - 复现（GitHub 经本机代理 `127.0.0.1:7897`）：
>   `git clone --depth 1 https://github.com/qt/qtdeclarative`；
>   `git clone --depth 1 --filter=blob:none --sparse https://chromium.googlesource.com/chromium/src && git -C src sparse-checkout set cc`；
>   `git clone --depth 1 --filter=blob:none --sparse https://github.com/flutter/engine.git && git -C engine sparse-checkout set impeller display_list`；
>   `git clone --depth 1 --filter=blob:none --sparse https://github.com/google/skia.git && git -C skia sparse-checkout set src include`；
>   WebRender 从 `raw.githubusercontent.com/mozilla-firefox/firefox/main/gfx/wr/webrender/` 按文件拉取。
>   （Firefox/Chromium 全量仓库过大，故用 sparse/定向拉取。）
>
> **注意**：以上仅作**机制参考**——我们的实现边界只有「Dart」与「既有 FFI 桥接」两处，
> 见 §4.0；不引入这些框架的运行时，也不改 Impeller/Skia/引擎。

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

### 3.3 WebRender（Firefox，源码精读）

**Picture caching（静态画面缓存，与我们「背景静态层」同构）**
- **tile 即缓存面**：默认 **1024×512**（滚动条 1024×32 / 32×1024）；有效 tile 不重栅格、只重新合成；
  每 tile 记 `device_dirty_rect` / `device_valid_rect` / `surface`：`tile_cache/mod.rs:73-91,254-283`。
- **失效原因枚举**（决定何时重做）：背景色、surface opacity 变化、无纹理/无面、prim 数量、
  内容、合成器类型、valid-rect、scale、underlay 取消：`invalidation/mod.rs:91-114`；
  `invalidate(rect, reason)` 置 `is_valid=false` 并并入脏矩形：`invalidation/cached_surface.rs:296-315`。
- **只在脏时挂纹理 + 建 `PictureCache` 任务**：`picture.rs:1784-1789,1858-1888`。
- **tile 回收**：上一帧未请求的 tile 过期（`last_access.frame_id < now-1`），
  GC 只保留 `ceil(allocated*0.25)` 空闲纹理、最旧先放：`picture_textures.rs:254-274,296-327`。
- **纹理池按尺寸复用**：`picture_textures.rs:135-197`；切片上限 `MAX_CACHE_SLICES=16`
  （超出压成单一原子缓存以约束显存）：`tile_cache/slice_builder.rs:33,82-87`。
- **廉价 tile 路径**：单个不透明 prim 的 tile 变成 `TileSurface::Color`（**不分配纹理**）；
  空 prim/空 valid-rect 的 tile 直接剔除并释放面：`tile_cache/mod.rs:570-591,472-485`。

**四叉树脏区（per-tile damage）**
- 叶子维持 `dirty_tracker: u64`（最近 64 帧）与 `frames_since_modified`；
  **分裂条件**：`level<3` 且 `frames_since_modified>64` 且近 64 帧脏 >50%：
  `invalidation/quadtree.rs:27-46,213-236`。
- **合并条件**：4 子节点全静态（脏帧=0）或全脏（=64）：`:238-268`；脏区输出为
  **单个并集矩形**（多处脏暂时不拆多矩形，TODO `tile_cache/mod.rs:261-262`）：`:394-434`。
- **部分更新需要平台能力**：静态 `gpu_supports_render_target_partial_update` 或
  `max_update_rects>0`，否则脏矩形强制等于整 tile：`tile_cache/mod.rs:533-563`。
- **顶点量化** `VERT_QUANTIZE_SCALE=4.0`（1/4 设备像素）用于内容比较：`invalidation/vert_buffer.rs:17`。

**遮挡裁剪**
- tile 遮挡：`Occluders{z_id, device_rect}` 用 y 轴扫描线比对**精确非重叠面积**，
  被完全覆盖则跳过栅格 + 合成 + 面分配：`composite.rs:1824-1963`、查询 `picture.rs:1724-1761`。
- 合成层前→后矩形遮挡：`FrontToBackBuilder` 把被遮挡矩形拆成最多 4 个子矩形：
  `rectangle_occlusion.rs:73-143,147-207`。

**合批**
- `BatchKey{kind, blend_mode, textures, readback}` 全等才可合并：`batch.rs:211-236`；
  不透明/透明分表：`:713-735`；向后查找合并直到边界重叠，`BATCH_LOOKBACK_COUNT=10`：
  `renderer/init.rs:236`、`batch.rs:356-423`。
- **大遮挡物阈值**：面积 > **屏幕/4** 的批次插到表首、不与更早批次合并：`batch.rs:464-495`。
- **跨任务合批**：`can_merge = !needs_scissor_rect` 时把 AlphaBatchContainer 并入
  同 render target 容器：`render_task.rs:480`、`render_target.rs:250,260-264`。
- 段溢出回退：`MAX_SEGMENTS=64` 时对整体包围盒只发 1 个带 mask 的段，避免病态切分；
  edge-flag 抗锯齿只处理暴露边：`segment.rs:13,482-495,501-518`。

**渲染任务图 / pass 合并**
- pass 数 = 任务依赖深度（拓扑分层），**不是固定几遍**：`render_task_graph.rs:443-491`；
  一个 `RenderTargetList` 可含多张纹理，使上一遍结果一次采样完，最大化合批：
  `render_target.rs:64-88`。
- 面生命周期：`assign_free_pass` 在最后一个消费者后归还纹理池、可被后续 pass 复用：
  `render_task_graph.rs:749-756,1002-1035`。
- 共享面：多任务打包进一张 `max_shared_surface_size=2048` 纹理（Guillotine），
  超出按 256 取整：`render_task_graph.rs:38,544-590`。
- **缓存任务**：`render_task_cache.rs` 键控复用；纹理句柄失效或 **10 帧**未用即失效，
  `MAX_CACHE_TASK_SIZE=4096`：`render_task_cache.rs:26,107-156,274-339`。

**纹理缓存 / 图集 / 上传**
- 共享区域 `TEXTURE_REGION_DIMENSIONS=512`，超 512 走独立纹理：`texture_cache.rs:44,1395-1399`。
- **7 个独立预算**（避免不同负载互相驱逐）：`texture_cache.rs:255-299`；
  独立纹理 **8 MiB**、共享「理想利用率」`bytes/3`（字形 `×2/3`）、
  **每帧最多 32 次驱逐**、年龄阈值随压力 400→…→1：`:1119-1219`；前一帧用过的绝不驱逐：`:1237-1245`。
- 上传合批：单 `TextureUploader` + `BATCH_UPLOAD_TEXTURE_SIZE=512×512`，PBO 批量：
  `renderer/upload.rs:8-14,44-45,81-85`；Guillotine：`NUM_BINS=3`、
  `MIN_RECT_AXIS_SIZES=[1,16,32]`、请求按 8 对齐：`texture_pack/guillotine.rs:10-13,184-206`。

### 3.4 Flutter / Impeller（源码精读，**我们的主运行层**）

**pass 创建与「合并」行为**
- `Canvas` 持 `render_passes_` 栈（每层一个 `EntityPassTarget` + `InlinePassContext`）：
  `display_list/canvas.h:94-113`；`InlinePassContext::GetRenderPass()` **懒创建并复用同一
  command buffer + RenderPass，直到 `EndPass()`**：`entity/inline_pass_context.cc:74-151`。
- load/store 在创建时定死：首 pass `kClear`，后续 `kLoad`（MSAA 时 `kDontCare`）：
  `inline_pass_context.cc:106-140`；空 draw 被 `AddCommand` 丢弃：`renderer/render_pass.cc:62-76`。
- **强制新 pass / 离屏的事件**：`SaveLayer`（`canvas.cc:1146-1152`）、子 pass `Restore` 合成
  （`:1213-1293`）、**无 framebuffer fetch 的高级混合**（`:1261-1289,1487-1520`）、
  backdrop filter（`:1078,1546-1659`）、readback（`:877-897`）、onscreen blit（`:1661-1714`）。
  **仅换混合模式不破 pass**；pass **不会回并**。整个 DL 在 CPU 上**派发两遍**：
  `dl_dispatcher.cc:1266-1279`。
- **结论**：Impeller 的「合并」= 同一层内多次 draw 进同一 pass；真正贵的是
  **saveLayer / 高级混合 / backdrop / filter / readback**（每个都 = 新 pass + 离屏纹理 + 全量采样）。

**批处理 / 不透明快路径**
- 跨 entity **不做 run 合并**；批处理只在「已含多图元」的 op 内（文本一次 vertex buffer：
  `entity/contents/text_contents.cc:162-166,279-283`；图集/顶点：
  `atlas_contents.cc:71-87`、`vertices_contents.cc:133-185`）。
- **不透明强制** `kSourceOver→kSource`（可深度写/重排）：`canvas.cc:1450-1453`；
  **纯色铺满被吸收进 clear color**，不发 draw：`canvas.cc:1455-1475`、
  `solid_color_contents.cc:72-79`。
- 管线键为 64-bit `ContentContextOptions::ToKey()`：`content_context.h:339-358`。

**裁剪**
- 深度裁剪，每个真实 clip 发 **2 次 draw**（stencil 预备 + 覆盖）：
  `entity/contents/clip_contents.cc:69-146`；`kDepthEpsilon=1/262144`、`kMaxDepth=1<<24`：
  `entity/entity.h:25`、`display_list/canvas.h:117`。
- **廉价路径**：轴对齐、边距整数 < `threshold=0.124`（或非 AA）的相交 clip
  **完全跳过 stencil、只更新 scissor**：`entity/entity_pass_clip_stack.cc:149-172`；
  scissor 仅在 clip 状态变化时更新：`canvas.cc:604-609`。

**离屏 / 滤镜（最大填充率来源）**
- `Contents::RenderToSnapshot` 分配离屏 subpass，coverage 外扩 **1px**、按 `ceil` 定尺：
  `entity/contents/contents.cc:56-119`。
- 高斯模糊**最多 4 pass / 3 个 command buffer**（downsample + H + V 乒乓），
  `kMaxSigma=500`、kernel 上限 50→内部 100、radius≥3 丢 2 采样、downsample 分支 0.5/0.125/0.0625：
  `entity/contents/filters/gaussian_blur_filter_contents.cc:700-847,27`、`.h:17`。
- `saveLayer` 离屏尺寸按 coverage 取整并夹到最大附件尺寸：`canvas.cc:985-1029`；
  **opacity peephole**（alpha 可分配时直接跳过子 pass）：`canvas.cc:973-979`、
  `dl_dispatcher.cc:319-325`；backdrop filter 按 `backdrop_id` 复用同一快照：`canvas.cc:1046-1138`。
- 离屏 MSAA 为 `kCount4` 且 resolve 纹理标记 **`CompressionType::kLossy`**：
  `renderer/render_target.cc:398-457`。

**几何 / 缓存 / 分配**
- 凸填充走三角扇；**非凸不做正确剖分**，改 `kNonZero/kEvenOdd` + stencil-then-cover（2 次 draw）：
  `entity/geometry/fill_path_geometry.cc:41-75`、`color_source_contents.h:142-205`；
  描边 `kPreventOverdraw`：`color_source_contents.h:231-267`。
- `Tessellator` 跨调用保留 point/index 缓冲并缓存三角 `kCachedTrigCount=300`：
  `tessellator/tessellator.h:314-324`。
- `ContentContext::Variants` 为**按 64-bit key 线性扫描、无驱逐**的 vector：
  `content_context.h:796-857`；`RenderTargetCache` 按 `{size,mips,msaa,depth}` 配置复用、
  保活若干帧：`entity/render_target_cache.cc:11-139`。

### 3.5 Skia（源码精读，Flutter 非 Impeller 后端 / `dart:ui` 底层）

**字形 / 文本缓存（对歌词最直接）**
- 字形 strike：`SkDescriptor → SkStrike`，CPU 默认预算 **2 MiB / 2048 项**：
  `src/core/SkStrikeCache.h:31-37`；purge 目标 `max(超限, 25%)`，尾部逐出、跳过 pinned：
  `src/core/SkStrikeCache.cpp:216-275`。
- **亚像素相位 4×4**（`SkPackedGlyphID`，`kSubpixelRound=0.125`）：`src/core/SkGlyph.h:46-70`；
  mask 格式 `BW/A8/LCD16/SDF`：`src/core/SkMask.h:23-33`；LCD 在 >**48px** 关闭：
  `src/core/SkScalerContext.cpp:1158-1176`。
- GPU 侧 strike 独立预算同样 2 MiB/2048：`src/text/gpu/StrikeCache.h:24-30`；
  **GPU text-blob 复用缓存 4 MiB LRU**：`src/text/gpu/TextBlobRedrawCoordinator.h:34-40`。
- SDF：magnitude 4 / pad 4，SDF 适用于 ≥18px、>**384**（macOS 256 / Android 324）转路径：
  `src/core/SkDistanceFieldGen.h:18-30`、`src/text/gpu/SubRunControl.cpp:30-35`。
- 图集字形尺寸上限 `kSkSideTooBigForAtlas=256`（最小 plot 256×256）：`src/core/SkGlyph.h:333`。

**Ganesh 合批**
- op 回插合并：向后线扫，遇**绘制序冲突（包围盒重叠）停止**，
  `kMaxOpChainDistance=10` / `kMaxOpMergeDistance=10`：`src/gpu/ganesh/ops/OpsTask.cpp:54-55,1090-1120,215-286`。
- 合批破坏条件：`classID`、`GrAppliedClip`、`requiresNonOverlappingDraws`、`requiresDstTexture`、
  dst proxy 不同：`:279-296`；文本 op 还对 DF/掩码/局部坐标/颜色/gamma 等差异拒绝合并：
  `src/gpu/ganesh/ops/AtlasTextOp.cpp:689-749`。
- flush 上限 `kMaxRenderPassesBeforeFlush=100`：`src/gpu/ganesh/GrDrawingManager.cpp:288`。

**图集 / 资源缓存**
- 三种掩码图集、`kMaxAtlasDim=2048`：`src/gpu/ganesh/GrDrawOpAtlas.h:286-291`；
  plot 256、`kMaxPlots=32`、多纹理页 ≤4：`src/gpu/ganesh/GrAtlasTypes.h:119-120`；
  32 个 flush 未用可驱逐、整页 128：`GrDrawOpAtlas.cpp:216-268`；ARGB 尺寸-预算表：`:580-611`。
- `SkCanvas::drawAtlas`：`src/core/SkDraw_atlas.cpp:73-89`、`ops/DrawAtlasOp.cpp:307-333`。
- 预算：Ganesh `GrResourceCache` **256 MiB**（LRU purge）：`GrResourceCache.h:89`、
  `GrResourceCache.cpp:472-515`；CPU `SkResourceCache` 图片 **32 MiB**：`SkResourceCache.cpp:50-51`；
  图片滤镜缓存 **128 MiB**（transient 32 MiB）：`SkImageFilterCache.cpp:24-26`。

**Graphite（新后端）**
- **排序后合并**：128-bit `SortKey`（颜色/深度序、stencil、render step、管线、uniform、纹理绑定）
  排序以减少切换，相邻等价管线合并成更少更大的 draw：`src/gpu/graphite/DrawList.h:49-63,191-204`；
  snap 时仅在 key 变化时发状态命令：`DrawList.cpp:160-235`。
- `kMaxRenderSteps=4`/`4096`：`Renderer.h:344`、`DrawListBase.h:49`；
  本次 checkout 仍 `passes.size()==1`（**尚未做 subpass 合并**）：`task/RenderPassTask.cpp:75-76`；
  预算 256 MiB：`include/gpu/graphite/ContextOptions.h:123`。

**滤镜 / saveLayer**
- `saveLayer` 分配真实离屏 `SkDevice`（按层边界定尺）：`src/core/SkCanvas.cpp:1007-1078`；
  `trivialRestore` 可避免：`:926-934`；`kMaxFiltersPerLayer=16`：`src/core/SkCanvas.cpp:906`。
- **多遍降采样**：`downscale_step_count=ceil(log2(1/netScale))`，大 blur 走逐级 ½ 缓冲：
  `src/core/SkImageFilterTypes.cpp:1479-1497`；sigma 上限 532（CPU 135）：
  `src/effects/imagefilters/SkBlurImageFilter.cpp:151,201`。

### 3.6 Flutter engine `flow`（源码精读：光栅缓存 / 损伤 / 图层）

**光栅缓存（RasterCache）**
- 键分 `kLayer / kLayerChildren / kDisplayList`：`flow/raster_cache_key.h:24,78,96-104`。
- **层缓存准入**：尝试次数 `>= threshold`（计数器从 1 起，默认 threshold=1）；
  `OpacityLayer` 自身永不缓存（`layer_cached_threshold=INT_MAX`）但允许缓存子块：
  `flow/layers/layer_raster_cache_item.cc:44-78`、`layer_raster_cache_item.h:19-21,64-69`。
- **DisplayList 复杂度阈值**：GL/Metal `complexity_score > 200000`（注释「≈1ms」），
  Naive/软件 `op_count > 5`：`display_list/benchmarking/dl_complexity_gl.h:23-26`、
  `dl_complexity.h:41-47`。
- **每帧最多新建 3 个 DL 缓存**；且需**连续可见 ~3 帧**（`access_threshold=3`）才入缓存：
  `flow/raster_cache.h:139-142`、`raster_cache_util.h:21`、`display_list_raster_cache_item.cc:103-123`。
- **无字节/条目上限**：唯一回收是「本帧未见即逐出」（非 LRU/非内存压力）：
  `flow/raster_cache.cc:144-155,214-232`。
- 键**忽略平移**（层滑动不失效，缩放/旋转会失效）：`raster_cache_key.h:87-91`；
  `ImageFilterLayer` 需渲染 **3** 次后才缓存：`raster_cache_util.h:37`。
- ⚠ **该缓存是 Skia 专用**（`#if !SLIMPELLER`，Impeller 构建编译掉）——
  桌面若走 Impeller，`RepaintBoundary` 的实际缓存收益需实测确认（见 §8.8）。

**损伤区 / 部分重绘**
- `Damage = frame_damage + buffer_damage`（后者含历史累积），绘制按 damage 裁剪：
  `flow/diff_context.h:22-35`；`ComputeClipRect` 用上一帧 `paint_region_map` 差分：
  `compositor_context.cc:14-45`。
- 保留层差分：前后缀相同（`IsReplacing`）且无 readback/texture 的子树**直接复用上一帧区域**：
  `flow/layers/container_layer.cc:39-103`。
- **Impeller 仅在 damage 非全屏且某轴比例 ≤ `kImpellerRepaintRatio=0.7` 时**才部分重绘：
  `flow/compositor_context.cc:195-221`；否则整帧。
- Dart 侧唯一直接开关：`SceneBuilder.addPicture(isComplexHint, willChangeHint)` →
  引擎 `is_complex`/`will_change`（`willChangeHint` 会**抑制**缓存）：
  `lib/ui/compositing.dart:515-520`、`lib/ui/compositing/scene_builder.cc:220-237`。

**图层 → saveLayer 规则**
- `ContainerLayer::PrerollChildren` 用不重叠检测把后面被覆盖的孩子的可渲染状态清零：
  `container_layer.cc:122-167`。
- 能让孩子自己携带 alpha（`kCallerCanApplyOpacity`）就避免 `saveLayer`：
  `flow/layers/layer_state_stack.h:225-230`、`opacity_layer.cc:36-68`。
- `ClipRectLayer` **只有 `Clip.kAntiAliasWithSaveLayer`** 才真 `saveLayer`，普通裁剪只是 clip：
  `clip_shape_layer.h:44-105`。

### 3.7 Flutter framework（`rendering/` + `widgets/` 源码精读）

**重绘边界 / 图层复用（我们最直接的杠杆）**
- `isRepaintBoundary` 默认 false，`RenderRepaintBoundary` 为 true；`markNeedsPaint` 走到边界即停、
  把**脏回溯**截断在边界：`rendering/object.dart:3112,3368-3408`。
- 仅 alpha/filter 变化时走 `updateLayerProperties`，**复用 display list、不重绘子树**：
  `object.dart:1293-1333`；`_compositeChild` 在 `!_needsPaint && _wasRepaintBoundary` 时**原样复用图层**：
  `object.dart:249-291`。
- 布局边界规则 `_isRelayoutBoundary`（紧约束 / 不依赖父尺寸即可局部化重排）：`object.dart:2893`。

**合成提升（compositing promotion）**
- `_needsCompositing = 子需要 || isRepaintBoundary || alwaysNeedsCompositing`：
  `object.dart:3274-3306`。
- **分数 `Opacity` 会强制 `alwaysNeedsCompositing` + 边界**，把整条祖先链提升为合成并加边界：
  `proxy_box.dart:897-900`；`ShaderMask`/`BackdropFilter`/`ImageFiltered`/`ColorFiltered`/
  `Transform(filterQuality)` 同理自动合成。
- 帧顺序：`flushLayout → flushCompositingBits → flushPaint → compositeFrame`：
  `rendering/binding.dart:691-702`。

**列表 / Sliver（全应用重点）**
- 默认 `cacheExtent = 250` 逻辑像素（两侧）；viewport 仅在溢出时裁剪、本身是重绘边界：
  `rendering/viewport.dart:289,749,970-982`。
- `RenderSliverList` 构建到 `targetEndScrollOffset`（含 cache）后 `collectGarbage` 回收视口外：
  `rendering/sliver_list.dart:262-332`；**cache 内的孩子仍会 build + layout**。
- 已知 `itemExtent` 时用 `SliverFixedExtentList`（按 index 算偏移，无逐子布局）：
  `sliver_fixed_extent_list.dart:410-494`。
- delegate 默认 `addRepaintBoundaries` / `addAutomaticKeepAlives` / `addSemanticIndexes` 全 true：
  `scroll_delegate.dart:560-572`；`AutomaticKeepAlive` 会把离屏 child 留在 `_keepAliveBucket`：
  `sliver_multi_box_adaptor.dart:355-419`。

**图片 / 可见性 / 效果**
- `Image.cacheWidth/cacheHeight` 是**物理像素**解码尺寸，直接决定 `ImageCache` 内存：
  `widgets/image.dart:314-332`。
- `TickerMode(enabled:false)` 只静音 ticker（时间仍走）；`Offstage` 仍**布局**、只是不绘制；
  `Visibility` 默认直接移除子树（丢状态）、`maintainAnimation:false` 才包 `TickerMode`：
  `widgets/ticker_provider.dart:394-400`、`rendering/proxy_box.dart:3833-3889`、
  `widgets/indexed_stack.dart:464-473`。
- `Opacity` 仅 1.0/0.0 有快路径；`Clip` 默认 `antiAlias`（非 saveLayer）；`ImageFiltered` 是
  重绘边界 + `ImageFilterLayer`：`widgets/basic.dart:352-353`、`rendering/layer.dart:1607,1697`、
  `widgets/image_filter.dart:98-108`。
- `AnnotatedRegionLayer` 每次 paint 都重建（非保留层）——**热路径避免**：`proxy_box.dart:4672-4683`。

### 3.8 Dear ImGui（源码精读：批处理 / 图集 / 裁剪）

- **批处理**：始终预置一个 `ImDrawCmd`，图元直接追加；**只有** clip 变化、纹理变化、
  顶点偏移溢出（16-bit `1<<16`）、用户回调、channel 切换才新开 cmd；
  且新 cmd 为空且 idx 连续时会**合并回去**：`imgui_draw.cpp:461-474,591-652,577-587,737-744`。
- 顶点/索引用**写游标**顺序追加，`PrimReserve/PrimUnreserve` 只调 `resize` + 指针推进：
  `imgui_draw.cpp:733-767`；每帧只 `resize(0)` 保留容量（不释放）：`:461-463,478-492`。
- **图集**：`TexGlyphPadding=1`、最小 `512×128`、最大 `8192`，stb_rect_pack 打包，
  增长按 2 的幂、优先正方形；当「丢弃面积 < 打包面积 20%」时原地重排而不扩张：
  `imgui_draw.cpp:2672-2686,4231-4261`；白色像素 UV 供纯色填充、线条 UV 供 AA 线：
  `:3638,3654-3702`。
- **镶嵌容差**：`CurveTessellationMaxError=1.12`、`CircleTessellationMaxError=0.30`，
  圆分段夹在 `[4,512]`，1/4 圆弧查表 48 段：`imgui.cpp:1579-1580`、
  `imgui_internal.h:872-885`。
- **AA 成本**：`_FringeScale = 1/pixel_density`，AA 填充 `n*6` 索引 / `n*2` 顶点：
  `imgui_draw.cpp:723-728,1099-1153`。
- 对 Dart 的启示：**持久 append-only 顶点/索引缓冲 + 写游标**；同状态图元（列表行、频谱柱、
  字形 quad）应合并到一条 draw；纯色用白像素 UV、字形共用一个图集。

### 3.9 Slint（源码精读：脏区 / 部分渲染 / 项目缓存）

- **DirtyRegion 上限 3 个矩形**（内联数组，无分配），满时并入「增长最小」者：
  `internal/core/partial_renderer.rs:258-317`；每个可渲染项带 `CachedRenderingData`
  （`cache_index` + `cache_generation`）跨缓存清理校验：`:42-48`。
- **脏区计算**：`compute_dirty_regions` 自后向前比较几何（`same_geometry`）、
  `PropertyTracker::is_dirty`、兄弟顺序 rank；`filter_item` 直接**跳过不与脏区相交的项**
  （连文字 shaping 都省）：`:449,543-654,740-809`。
- **`PartialRendererCache`**：slab + `generation`（初值 1）；无容量上限：
  `:208-253`。`RepaintBufferType::{NewBuffer,Reused,Swapped}` 决定全新/仅脏/近两帧并集：
  `:380-394`。
- Skia 后端仅「CPU 表面或 `SLINT_SKIA_PARTIAL_RENDERING`」才部分渲染，脏区作为
  `clip_rect`/`clip_path`；`back_buffer_age` 用 3 帧历史：`internal/renderers/skia/lib.rs:338-347,916-923,383-384,771-782`。
- **逐项缓存**：`ItemCache<T>`（per component/item + `PropertyTracker` 自动失效）承载
  image/layer/path/box-shadow 缓存；box-shadow 全局池 `MAX_CACHED_SHADOWS=16`（LRU）：
  `internal/core/item_rendering.rs:38-90`、`internal/core/graphics/boxshadowcache.rs:175,236-244`。
- **有界预算**：解码图缓存 **5 MiB** `CLruCache`：`internal/core/graphics/image/cache.rs:49-58`；
  Skia 字体缓存 **64** 项、软件字形缓存 **1 MiB**（4 个亚像素分箱）、
  parley 布局缓存 `ENTRY_LIMIT=1024`：`internal/renderers/skia/font_cache.rs:12`、
  `internal/renderers/software/fonts/vectorfont.rs:68,29`、
  `internal/core/textlayout/sharedparley/cache.rs:43`。
- 软件渲染只对脏区做背景填充并按行裁剪已覆盖前缀：`internal/renderers/software/lib.rs:559-707,1322-1360`。

### 3.10 可迁移机制清单（附源码出处）

| 机制 | 源码出处 | 我们对应的落点 |
|---|---|---|
| 图层缓存 / FBO 复用（脏标志驱动） | Qt `qsgrhilayer.cpp:68-81`；WR `tile_cache/mod.rs:254-283`；`cc` `effect_node.h:224-226` | 背景**静态层**、播放条、侧边栏包 `RepaintBoundary` |
| 只更新损伤区（需平台能力） | WR `invalidation/quadtree.rs:394-434`、`tile_cache/mod.rs:533-563`；`cc` `tile_manager.cc:1509-1516` | 水纹**动态层**只画活动涟漪（Flutter 无 RT partial-update API，只能层隔离近似） |
| 降分辨率 / LOD | `cc` `tile_size_calculator.cc:67-85`；Skia `SkImageFilterTypes.cpp:1479-1497` | 动态层低分辨率离屏、静态层 1/2~1/4 预烘焙 |
| 内存上限 + 优先级/空闲回收 | WR `texture_cache.rs:1119-1219`、`picture_textures.rs:296-327`；Skia `GrResourceCache.h:89`；`cc` `tile_manager.cc:912-1092` | 图片/图层缓存上限、空闲回收 |
| 遮挡裁剪 / 不可见即停 | WR `composite.rs:1824-1963`、`rectangle_occlusion.rs:73-143`；`cc` `occlusion_tracker.cc:129-226`；Qt `qsgnode.cpp:1329` | `Offstage`/`Visibility` + `TickerMode`（已有，扩展） |
| 合批（键相等 / 序冲突即断） | Impeller `text_contents.cc:162`；Skia `OpsTask.cpp:54-55,279-296`；Qt `qsgbatchrenderer.cpp:1800-1946`；WR `batch.rs:211-236` | 频谱单 Path（已 P3）→ 评估 `drawAtlas`；歌词字形缓存 |
| 裁剪代价（轴对齐整数 clip 才走 scissor） | Impeller `entity_pass_clip_stack.cc:149-172`；Qt `qsgbatchrenderer.cpp:2440-2479` | 减少 `ClipRRect`/AA 圆角/`saveLayer`，列表 delegate 内禁止 |
| 离屏 pass 是最大开销（不合并回） | Impeller `canvas.cc:1146-1520`、`contents.cc:56-119`；Skia `SkCanvas.cpp:1007-1078` | 禁全屏 `BackdropFilter`/`ImageFiltered`；滤镜限小层 |
| 不透明快路径 | Impeller `canvas.cc:1450-1475`；`cc` `layer.cc:894-900`；Qt `qsgbatchrenderer.cpp:1545-1549` | 避免无谓半透明/模糊叠层 |
| 字形缓存很小会抖 | Skia `SkStrikeCache.h:31-37`（2 MiB）、`TextBlobRedrawCoordinator.h:34-40`（4 MiB）；Qt SDF 图集 LRU | 我们的 Paragraph 缓存用有界 LRU，避免无界增长 |
| 图片按显示尺寸解码 + 解码缓存上限 | `cc` `image_decode_cache_utils.cc:20-38`；Skia `SkResourceCache.cpp:50-51` | 沿用 `CoverImage` `cacheWidth/Height` + `ImageCache` 上限 |
| 生命周期 / Loader | Qt `Loader`+`destroy()`；WR `picture_textures.rs:254-274` | 页面分支卸载、模块注册表、图片缓存上限 |
| 后台节流（连 ticker 一起停） | `cc` `scheduler_state_machine.cc:1481-1503`；Qt `qsgthreadedrenderloop.cpp:993-998` | `power_saver.dart` + `FrameGovernor` |

---

## 4. 我们的方案

### 4.0 实现边界与模块归属（硬约束）

> **约束（用户 2026-09-16）**：UI 是 Dart 写的——**所有优化必须在 Dart 或既有 FFI 桥接层实现**，
> 并**保证架构模块化**。§3 的跨框架机制只作**参考**，不引入其运行时/依赖。

**可落点（只有两处）**
1. **Dart 层**：Flutter widget / `CustomPainter` / `dart:ui`（`Picture`、`Image`、`ImageFilter`、
   `FragmentProgram`、`Canvas`）/ Riverpod / `SchedulerBinding`。
2. **既有 FFI 桥接**：`app/native/platform`（`include/archoera_platform.h` 的 `apl_*` C ABI，
   三端后端 + `backend_stub.cpp`）。**仅**用于「系统能力」类需求（如 GPU/显示器信息、窗口状态），
   且按 `AGENTS.md` 流程扩 ABI；**不得**在 Dart 直调平台 API、不得 `Process.run`/MethodChannel。

**机制 → 实现层映射（对照 §3，避免「抄了个跑不起来」）**

| §3 机制 | 能否在 Dart 实现 | 实现手段 |
|---|---|---|
| 图层隔离 / 缓存 | ✅ | `RepaintBoundary`、`TickerMode`、`Offstage`、`Visibility` |
| 静态层预烘焙（模糊封面+压暗） | ✅ | `PictureRecorder` + `Picture.toImageSync` / `ImageFilter` / `ColorFilter` → `ui.Image` |
| 动态层低分辨率离屏 + 放大 | ✅ | 小尺寸 `PictureRecorder` → `toImageSync` → `Canvas.drawImageRect` |
| 折射 / 高光 / 压暗逐像素 | ✅ | `FragmentProgram`（`app/shaders/*.frag`）+ `CustomPainter` |
| 缓存预算 / LRU 驱逐 | ✅ | `PaintingBinding.instance.imageCache`（`maximumSizeBytes`）+ 自研有界 LRU |
| 自适应画质档位 | ✅ | `SchedulerBinding.addTimingsCallback` 滑窗 → 档位（复用 `FrameGovernor`） |
| 页面/模块生命周期 | ✅ | go_router 分支 + Riverpod；原生模块走既有注册表规划 |
| **驱动 Impeller/Skia 的 pass 合并 / 渲染目标部分更新 / tile 栅格** | ❌ | 无公开 API——只能用**层隔离 + 局部绘制**近似 |
| **多进程 GPU 模型 / 自写 GPU 后端 / fork 引擎** | ❌ | 明确放弃（见 §7） |

**GPU 依赖边界（硬约束，用户 2026-09-16）**
- **默认按集显设计、优先集显运行**：效果预算以 iGPU 为基线，**不选独显、不要求独显**；
  多 GPU 机器上不主动请求高功耗 GPU。
- **禁止诱导切换独显**：不导出 `NvOptimusEnablement` / `AmdPowerXpressRequestHighPerformance`
  等标志；不通过创建高功耗上下文 / 大显存分配「钓」独显。
- **不使用独显专属特性**：compute shader、storage buffer、geometry shader、大 UBO、
  高倍 MSAA 等一律不依赖（也与 §3 的 iGPU 约束一致）。
- **设备选择不在我们手里**：Flutter/Impeller 的 GPU 设备选择由引擎 + 驱动决定，
  Dart 无法可靠强制集显；因此策略是**把效果压到集显够用**，而非「指定 GPU」。
- 如需读取当前渲染器/GPU 信息用于画质分档，**只能经 `apl_*` 桥接**（系统能力），
  且**只读、不切换**；优先用帧时间自适应（§4.5），避免平台差异。

**模块化（单一职责、避免巨型文件）**
- `app/lib/widgets/player/background/`：拆 `player_background.dart`（档位选择）、
  `blurred_cover.dart`、`ripple_static_layer.dart`、`ripple_dynamic_layer.dart`、`ripple_shader.dart`
  （现 `ripple_background.dart` 单文件 687 行，应拆）。
- `app/lib/services/render/`：`layer_budget.dart`（图片/层缓存上限）、
  `quality_governor.dart`（帧时间→档位）、`damage_region.dart`（纯 Dart 脏区聚合）。
- `app/lib/services/lifecycle/`：`branch_lifecycle.dart`（分支卸载/重建）。
- `app/lib/services/native_module_registry.dart`：沿用 `module-on-demand-load-plan.md`。
- **共享 vs 平台**：跨平台逻辑放 Dart 共享层；平台特有逻辑放桥接各后端文件；
  桥接仍按官方工具链原生编译（不引入 Zig 承载）。

**验收（架构向）**：`dart analyze lib` 0 issue；**本方案新增代码**不引入 MethodChannel /
`Process.run`（既有 `window_manager` 等按桥接迁移路线另行收敛）；新增效果逻辑可单测
（纯 Dart 脏区/预算/档位算法）；单文件职责清晰、可独立测试与回退。

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
- **静态层的「失效原因集」可照抄 WR**：只有背景色、surface opacity、scale、valid-rect、
  纹理被逐出这几类才使 tile 失效（`invalidation/mod.rs:91-114`、`cached_surface.rs:283-315`）。
  对我们即：静态层仅在**切歌 / 尺寸变化**时重建，其余帧直接复用（`picture.rs:1784-1789`）。
- WR 回收：上一帧未请求的 tile 过期、GC 仅保留 25% 空闲（`picture_textures.rs:254-274,296-327`）
  ——对应「切歌即释放旧静态层/旧封面」。
- WR「单个不透明 prim 的 tile 不分配纹理」（`tile_cache/mod.rs:570-591`）——对应我们的
  纯色/渐变兜底层可完全不入纹理/离屏。

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
- **去离屏 pass（最高优先）**：Impeller 里 `saveLayer` / 高级混合 / backdrop / filter / readback
  **每个都新开 pass + 离屏纹理 + 全量采样，且 pass 不回并**（`canvas.cc:1146-1520`、
  `contents.cc:56-119`）；高斯模糊可达 **4 pass / 3 command buffer**
  （`gaussian_blur_filter_contents.cc:700-847`）。故清理无谓
  `ClipRRect`/`ClipRect`/`saveLayer`/`BackdropFilter`；列表 delegate 内**禁止**裁剪；
  已有 `ShaderMask` 渐隐并入画笔（P3）为先例。
- **裁剪优先「轴对齐、非 AA」矩形**：Impeller 对轴对齐、边距整数 < **0.124** 的相交 clip
  **跳过 stencil，只更新 scissor**（`entity_pass_clip_stack.cc:149-172`）；每个真实 clip
  则要 **2 次 draw**（`clip_contents.cc:69-146`）。Qt 同理：矩形走 scissor、非矩形才 stencil，
  且 **clipList 不同即无法合批**（`qsgbatchrenderer.cpp:2440-2479,1800`）。
  Flutter 侧优先 `ClipRect` 而非 `ClipRRect`，并尽量整数对齐。
- **正视 Flutter 的能力边界**：`dart:ui`/Impeller **未暴露「渲染目标部分更新」**
  （WR 也有 `max_update_rects>0` 的门槛，`tile_cache/mod.rs:533-563`）——所以我们的
  「损伤区」只能用**图层隔离（`RepaintBoundary`）+ 局部绘制**近似，不可能像 `cc` 那样真·脏矩形重栅。
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

### 4.6 全应用 UI 纪律（列表 / 图片 / 毛玻璃 / 转场）

> 目标面见 §2.1；原则仍是「图层缓存 / 只画变化 / 降分辨率 / 不可见即停」。全部 Dart 可做。

**列表 / 网格（除播放页外最大收益）**
- 已知行高用 `SliverFixedExtentList`/`itemExtent`（按 index 算偏移，无逐子布局）：
  `rendering/sliver_fixed_extent_list.dart:410-494`。
- `cacheExtent` 默认 **250** 逻辑像素/侧（`rendering/viewport.dart:289`）；**cache 内仍 build+layout**
  （`sliver_list.dart:262-332`），长列表应下调。
- delegate 默认 `addRepaintBoundaries=true`（每行一个层）；行内容轻时可关闭以减少层数，
  但要先测（`widgets/scroll_delegate.dart:560-572`）。
- 慎用 `AutomaticKeepAliveClientMixin`（离屏 child 常驻 `_keepAliveBucket`）：
  `sliver_multi_box_adaptor.dart:355-419`。
- 行内**避免** `ClipRRect`/阴影/`BackdropFilter`；封面圆角可改用预烘焙圆角图或小半径 `ClipRRect`（§3.4/§3.7）。

**图片 / 封面**
- 一律按显示尺寸解码：`Image.cacheWidth/cacheHeight`（**物理像素**）：
  `widgets/image.dart:314-332`（沿用现有 `CoverImage`）。
- 设 `PaintingBinding.instance.imageCache.maximumSizeBytes` 上限，并在路由退出 `evict/clear`
  （对照：Skia 资源缓存 256 MiB / 图片 32 MiB、Slint 解码图 5 MiB、`cc` 128 MiB；§3.5/§3.9/§3.1）。
- 全屏背景图走 §4.1 的静态层 + 降采样。

**毛玻璃 / 弹窗**（`widgets/common/glass_surface.dart`、登录/队列面板等）
- `BackdropFilter` 在 Impeller 下是**新 pass + 离屏纹理 + 全量采样**（§3.4）：限制 clip 范围、
  避免全屏；单控件过滤优先 `ImageFiltered`（`widgets/image_filter.dart:98-108`，§3.7）。
- 能不用模糊就不用——不透明/纯色优先（§3.4 `canvas.cc:1450-1475`）。

**转场 / 动画 / 常驻部件**
- 避免大范围 `Clip`、分数 `Opacity`、`ShaderMask` 动画：会触发合成提升与离屏
  （`proxy_box.dart:897-900`，§3.7）；性能模式已直切，其余用位移/小区域淡入。
- 侧边栏/顶栏/播放条：用 `RepaintBoundary` 隔离进度条/封面等高频变化区；热路径避免非保留层
  （如 `AnnotatedRegionLayer` 每次 paint 重建，`proxy_box.dart:4672-4683`）。
- 自管动画在隐藏时 `TickerMode(enabled:false)`；`Visibility` 默认移除子树（丢状态），
  需保状态用 `Offstage`（仍会布局）：`widgets/indexed_stack.dart:464-473`、`rendering/proxy_box.dart:3833-3889`。

> ⚠ **待实测**：§3.6 指出 `flow` 的 RasterCache 是 **Skia 专用**，Impeller 构建会编译掉——
> 因此 `RepaintBoundary` 在 Impeller 下的缓存收益需要实测确认（见 §8.8），再决定列表行是否保留边界。

---

## 5. 分期（可验收）

| 阶段 | 内容 | 实现层 / 模块（§4.0） | 验收 |
|---|---|---|---|
| **R0** | profile 基线：**全应用**（列表/首页/搜索/播放页）2K/4K，记录 UI/raster 帧时间 + GPU 占用（iGPU 与 llvmpipe） | Dart（`addTimingsCallback`）｜`services/render/quality_governor.dart` | 基线与瓶颈归属报告（分页面） |
| **R1** | 背景**静态层缓存** + **动态层损伤区** + 降分辨率（§4.1） | Dart｜`widgets/player/background/*`、`services/render/damage_region.dart` | iGPU 全屏达帧预算；视觉与上游一致；软渲染可回退 |
| **R2** | 图层纪律 + 生命周期（§4.2/§4.4）：稳定层隔离、去无谓裁剪、分支卸载、downloader 解除常驻 | Dart + FFI（模块注册表）｜`services/lifecycle/branch_lifecycle.dart`、`services/native_module_registry.dart` | RSS 可控、启动时间不退化；切页/切歌后可回收 |
| **R2b** | **全应用 UI 面**（§4.6）：列表/网格纪律、图片解码与缓存上限、毛玻璃范围、转场、常驻部件隔离 | Dart｜`widgets/list/*`、`widgets/common/glass_surface.dart`、`services/render/layer_budget.dart` | 列表滚动帧时间达标；图片常驻内存有界；无全屏模糊弹窗 |
| **R3** | 文本/几何批处理（§4.3，按 R1/R2 后剩余瓶颈定） | Dart｜`widgets/player/lyrics_v7/*`、`widgets/player/spectrum_view/*` | 歌词区 UI 帧时间≈常数；频谱无离屏 |
| **R4** | 自适应画质（§4.5） | Dart｜`services/render/quality_governor.dart` | 目标机稳定在帧预算内，无独显依赖 |

> 与专项文档的关系：`player-render-optimization.md` 的 **P0–P5** 仍有效；本方案的 **R1**
> 细化并**取代**其中「P2b 半分辨率」的单一手段，改为「静态层 + 损伤区 + 降采样」组合。
> **所有阶段均在 Dart 层实现**；除非确需系统能力（届时按 `AGENTS.md` 扩 `apl_*` ABI），
> 否则不触碰桥接与引擎。

---

## 6. 验收与指标

- **帧时间（全应用）**：DevTools Performance 分 UI / raster 线程；**播放页 + 长列表滚动 +
  首页/搜索** 60Hz 达帧预算（有余量再冲 120Hz）。
- **GPU 占用**：Linux `intel_gpu_top`/`radeontop`；Windows 任务管理器辅以 PresentMon/GPUView。
- **内存**：DevTools Memory，峰值/常驻 RSS；**图片/列表缓存有界**；切歌、切页、退出播放页后可回落。
- **启动时间**：冷启动到首帧；模块按需后不劣化。
- **正确性/回退**：涟漪不变量与上游一致；`FragmentProgram` 不可用 / 软渲染时功能可用；
  列表行为/滚动位置/图片占位不回退。
- **CI**：`dart analyze lib` 0 issue、`flutter test` 全绿（既有网络/凭据用例除外）。

---

## 7. 非目标

- **不引入 Chromium/Electron 的多进程模型**（GPU/渲染进程）：与 `AGENTS.md`
  「不新增进程承载图形/桥接、普通用户权限、同进程动态链接」冲突。
- **不引入外部渲染运行时**：不嵌入 WebView/Chromium/Qt、不依赖其源码/二进制；
  §3 的框架只作机制参考（实现边界见 §4.0）。
- 不自写跨平台 GPU 后端 / 不 fork Impeller；不改 Flutter 引擎；不驱动引擎内部 pass 合并。
- **不在 Dart 直调平台 API**（禁 MethodChannel / `Process.run`）；系统能力只能经 `apl_*` 桥接。
- **不依赖、不请求、不诱导独显**：不导出 Optimus / PowerXpress 等高功耗标志，
  不使用独显专属特性；不为「高级效果」牺牲 iGPU 可用性。
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
8. **Impeller 下 `RepaintBoundary` 还有多少缓存收益？**（§3.6 指出 `flow` RasterCache 是 Skia 专用、
   Impeller 编译掉）——需实测：同页面开关边界对 raster 帧时间的影响，再决定列表行是否保留边界。
9. **列表行边界与 `KeepAlive` 取舍**：默认 `addRepaintBoundaries=true` + `AutomaticKeepAlive`
   在长列表上的层数/内存代价，是否对某些列表关闭？
10. **图片缓存预算**：`ImageCache.maximumSizeBytes` 取值与页面退出 `evict` 策略（对照 Skia 32/128、
    Slint 5 MiB、`cc` 128 MiB）。
11. **毛玻璃降级**：`glass_surface` 等是否提供「无模糊」档，或缩小 `BackdropFilter` 范围？

---

## 9. 关联文档与参考

- [player-render-optimization.md](player-render-optimization.md) — 播放页三引擎专项（背景/歌词/频谱）
- [module-on-demand-load-plan.md](module-on-demand-load-plan.md) — 原生模块按需加载与释放
- [architecture.md](architecture.md)、[benchmark-2026-09-10.md](benchmark-2026-09-10.md)、
  [test-suite-2026-09-10.md](test-suite-2026-09-10.md)
- 上游实现：`SPlayer-Next/src/components/player/FullPlayer/PlayerBackground.vue`、
  `.../BackgroundRipple.vue`
- 外部机制参考（**源码级，§3.1–3.9**；克隆命令见 §3 引言）：
  - Qt `qtdeclarative@3027a40c`（dev）、Chromium `chromium/src@823ae20f`（main，仅 `cc/`）、
    Mozilla WebRender（`mozilla-firefox/firefox` main，`gfx/wr/webrender/`）、
    Flutter Impeller（`flutter/engine@ae5c3603`，`impeller/`）、Skia（`google/skia@9875bb59`）、
    Flutter engine `flow/`+`lib/ui/`（光栅缓存/损伤区/图层）、Flutter framework
    （`flutter/flutter@3cdba02`，`rendering/`+`widgets/`）、Dear ImGui（`ocornut/imgui`）、
    Slint（`slint-ui/slint`，`internal/`）。
  - 文档补充：Qt Quick Scene Graph / Performance
    （`doc.qt.io/qt-6/qtquick-visualcanvas-scenegraph.html`、`.../qtquick-performance.html`）；
    Flutter `dart:ui`：`RepaintBoundary` 层缓存、`FragmentProgram`、
    `ImageFilter.shader`（仅 Impeller，`painting.dart:4461`）、`Canvas.drawAtlas`。
