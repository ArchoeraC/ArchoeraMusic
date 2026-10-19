# 全屏播放页布局：注册表与模块化

> 状态：已实现（2026-10-18）——`default` / `fullscreen` / `vutron` 三种布局，
> 布局代码按模块拆分，通过注册表接入；新增布局不再修改播放页主体。
> 关联：[player-render-optimization.md](player-render-optimization.md)、
> [runtime-resource-optimization.md](runtime-resource-optimization.md)。

## 1. 为什么拆

播放页同时承担：播放状态、歌词引擎、背景、顶/底 chrome、自动沉浸、切歌动效。
早期用 `if (coverLayout == 'fullscreen')` 在主体里分支，新增一种排版就要同时改
页面、主体、封面/遮罩层，回归面大且容易互相影响。现在把「排版」收敛为独立
模块，页面只负责共享状态与外围 chrome。

## 2. 目录与契约

```
app/lib/pages/player/layouts/
├── player_layout.dart   # PlayerLayoutContext / PlayerLayout / 注册表
├── split_layout.dart    # default：封面 + 歌词左右分栏
├── poster_layout.dart   # fullscreen：整幅封面 + 信息置于歌词上方
└── vutron_layout.dart   # vutron：经典左封面 + 右侧歌词（自带控制区）
```

`PlayerLayout` 只暴露四个钩子：

| 钩子 | 职责 |
| --- | --- |
| `buildBackdrop` | 页面级附加层（整幅封面等），画在背景之上、内容之下；调用方包 `IgnorePointer` |
| `buildScrims` | 随自动沉浸淡出的遮罩（可空） |
| `buildBody` | 顶栏与底部控制之间的主体 |
| `usesDefaultBottomBar` | 是否使用页面共享的底部控制区 |
| `lyricsAlign` | 歌词水平对齐（居中 / 靠左 / 靠右；simple 与 AMLL 都生效） |

`PlayerLayoutContext` 是只读状态快照（当前曲目、歌词开关、封面 key、切歌动效、
页面尺寸、回调用 `onSeekLyric` 等）。布局**不要**自行订阅播放位置（每 50ms
重建）；歌词/进度由 `PlayerLyricsBlock`、`PlaybackProgressSlider` 内部订阅。

## 3. 新增一种布局

1. 新建 `xxx_layout.dart`，`extends PlayerLayout`，实现 `id` 与 `buildBody`
   （需要页面级封面/遮罩时再覆盖对应钩子）。
2. 加进 `player_layout.dart` 的 `playerLayouts` 列表。
3. 在 `prefs_player.dart` 的 `coverLayouts` 白名单与设置页分段里登记同一个 id；
   `test/player_layout_registry_test.dart` 会守卫两处一致，漏登记直接测试红。

未知 id（旧数据/降级）由 `playerLayoutFor` 回退 `default`。

## 4. 现有布局

- **default / split**：封面卡片 + 右侧歌词；`coverLyricRatio` 控制宽度比例，
  无歌词时封面自动居中。
- **fullscreen / poster**：封面铺满左侧整页高度（含顶栏/底栏背后）、右缘横向
  渐隐；标题/副标题左对齐放在歌词上方。封面在 `buildBackdrop` 中绘制，主体只
  排右栏，避免与顶栏/底栏挤压。
- **vutron**：对齐 VutronMusic Classic——左右两栏各半，左栏垂直居中（正方形
  封面 + 标题/副标题 + 进度 + 循环/上一首/播放/下一首/随机 + 音量），右栏歌词
  取 90% 宽右对齐；`lyricsAlign = left` 对 `simple`（原文/译文左对齐、
  其余行 0.95 缩放、上下 25% 渐隐）与 `amll` 物理墙同时生效。歌词颜色
  统一走偏好（已唱/未唱/跟随主题/跟随封面）。控制区在左栏内，不使用
  共享底栏。

## 5. 性能纪律（vutron 为例）

- **不新增渲染器**：`simple` 复用 `LyricsView`（行高实测缓存 + 懒加载列表），
  `amll` 复用 v7 物理墙；对齐作为段落属性 + 缓存键，不重算行高；
- **不做重复模糊**：封面投影用一层 `BoxShadow`，不复制封面再做 blur；
- **静态遮罩**：歌词上下渐隐用 SPlayer `.lyric-area` 的 10%/25% 非线性
  `ShaderMask`（0→60%→100%→100%→60%→0），整幅封面布局的顶/底遮罩用
  SPlayer `cover-mask` 的 8 段非线性 alpha，避免色阶与硬边；
- **封面渐隐**：优先用 `shaders/cover_mask.frag` 的横向直线距离 + 低频噪声
  扰动（每首封面用稳定 seed 轻微移动直线位置，避免机械的规则边界）；着色器
  不可用时回退同形状的 `LinearGradient`，测试环境走回退路径；
- **控制局部订阅**：进度/控制/音量各自 `Consumer`，位置 50ms 更新不带动整页；
- 需要模糊时优先「一次烘焙 + 复用」（见 `docs/runtime-resource-optimization.md`）。

## 6. 背景选项（与布局正交）

`coverTone`（封面主色）是背景选项而非布局：取当前封面主色派生低对比对角
渐变，纯色层绘制、无模糊/无图片，切歌 300–450ms 过渡；无封面时回退主题
渐变。与 `default` / `vutron` 等任意布局组合使用。

### 6.1 背景注册表

背景实现位于 `app/lib/widgets/player/background/styles/`，通过
`player_background_registry.dart` 的 `playerBackgrounds` 注册；`PlayerBackground`
只负责解析偏好快照与切换，不再维护 `switch (playerBgType)` 分支。新增样式：

1. 在 `styles/` 新建模块并实现 `PlayerBackgroundStyle`（`id` + `build`）；
2. 加进 `playerBackgrounds`；
3. 在 `prefs_player.dart` 的 `playerBgTypes` 与设置页下拉里登记同一个 id；
4. `test/player_background_registry_test.dart` 会守卫注册表与偏好白名单一致。

切换背景样式时统一经 `CrossFadeSwitcher` 做 200ms `ease` 交叉淡化，避免
模糊 ↔ 水纹等组合硬切；`blur` / `ripple` 内部的切歌交叉淡化（500ms / 700ms）
保持不变。无封面时 `blur` / `ripple` / `fluid` / `coverTone` 均回退主题渐变。
