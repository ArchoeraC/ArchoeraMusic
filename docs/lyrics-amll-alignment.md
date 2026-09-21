# 歌词表现层：AMLL 效果对齐（Lyrics AMLL Alignment）

> 状态：**已实现（2026-09-20）**。
> 范围：AMLL 引擎（`lyrics.engine = 'amll'`）的**表现层**——时钟、扫亮、景深、
> 逐词动画、间奏点、背景人声行。布局/弹簧/缓存的既有设计不变。
> 上游参考：`amll-dev/applemusic-like-lyrics`（`packages/core/src/lyric-player`，MIT）。
> 关联：[player-render-optimization.md](player-render-optimization.md) §4.2 / §4.2b、
> [architecture.md](architecture.md) §10.2。

---

## 1. 为什么做

我们的 v7 引擎骨架与 AMLL 同源（闭式弹簧 `solveSpring`、锚点/高亮分离、级联
50ms/1.05 衰减、掩码式高亮思路），但**表现层几乎全缺**。AMLL 是 DOM 结构，每个
字/词一个 `<span>`，因此可以：

- 逐字独立做 `transform` / `text-shadow`（上浮、长音强调）；
- 用 CSS `mask-image` 做**羽化渐变扫亮**；
- 对整行做 `filter: blur()` 景深。

Flutter 的 `ui.Paragraph` 做不到逐 run 变换、也不能给文字直接加 `ImageFilter`，
所以这些效果需要重新设计实现方式（见 §3）。

---

## 2. 对齐清单

| AMLL | 我们 | 文件 |
|---|---|---|
| rAF 每帧驱动 `currentTime` | `LyricClock`：事件位置 + vsync 外推（上限 150ms） | `lyric_clock.dart` |
| `mask-image` 渐变扫亮（未唱 .4 / 已唱 1.0，羽化 `wordFadeWidth×字高`） | 逐字 `dstIn` 线性渐变遮罩 | `lyrics_fragment_render.dart` + painter |
| 非激活行 `blur(1+distance)` + `scale .97` + opacity | 指数平滑的 `_blur` / `_scale` / `_fade`（无逐行弹簧对象） | `lyrics_physics_wall_state.dart` |
| `float` 每词 0→-0.05em（BG ×2） | `resolveWordAnim` 的 `dy` | `lyrics_word_anim.dart` |
| `emphasize` 长音脉冲（`empEasing` 0→1→0）+ 白辉光 + 缩放 + 推挤 + bob | 同参数；辉光用 `ui.TextStyle.shadows` | `lyrics_word_anim.dart` + painter |
| `interlude-dots`（≥7s 空隙） | `computeInterludes` + `resolveInterludeDots` | `interlude_dots.dart` |
| `isBG` 背景人声（整行括号判定） | `LyricGroup.isBG`（解析期剥离括号） | `services/lyrics/lyric_line.dart` |
| `cubic-bezier` 手搓缓动 | `cubicBezier` / `empathEasing` | `curves.dart` |
| `getPosYSpringPolicy` 按行间隔自适应弹簧 | `resolvePosYSpringPolicy` | `spring_policy.dart` |
| `.lyricLineWrapper` 排版度量（`line-height:1.2` + `padding:.4em` + `gap:.3em`） | `kLyricLineHeightEm=1.2` / `kLyricLineGapEm=0.8` / `kLyricTranslationGapEm=0.3` | `lyrics_layout.dart` |
| `LayoutReason` 策略（只有 PlaybackTick 带级联；`snapPosY` 仅连续拖拽） | `_maybeRetarget(stagger:/snapNow:)` + 触摸拖拽跟手 | `lyrics_physics_wall_state.dart` |
| RebuildView 时 `resetPosition`（整墙从下方飞入，不瞬移） | `_flyIn`：新歌/首帧把各行放到视口下方再由弹簧归位 | `lyrics_physics_wall_state.dart` |
| 音译（罗马音）小字 + `showRomanization`（main 已实现） | 与本轮的逐字/间距/弹簧改动合并保留（音译在译文**之上**） | `lyric_line.dart` / `lyrics_layout.dart` / painter |

### 2.1 关键常量（与上游一致）

- 未唱 / 已唱透明度：**0.4 / 1.0**（`--dark-mask-alpha` / `--bright-mask-alpha`）。
- 羽化宽度：`wordFadeWidth(默认 0.5) × 字号`。
- 时钟外推上限：**150ms**（上游 `MAX_FRAME_DELTA` 100ms 的同量级取值）。
- 间奏最小空隙：**7000ms**；进场淡入 180ms / 退场总长 1000ms（前 750ms 胀到
  1.25、后 250ms 缩到 0.4）/ 每点错峰 80ms / 呼吸周期基准 4000ms。
- 长音强调门槛：时长 ≥1000ms（CJK 不限字数；拉丁词 2~7 字符）；末词
  `amount×1.6 / blur×1.5 / du×1.2`。
- 级联：`kCascadeStepMs = 50`、`baseDelay /= 1.05`（原有，未变）。

---

## 3. 实现要点

### 3.1 逐字渲染（`lyrics_fragment_render.dart`）

`ui.Paragraph` 不能逐 run 变换，所以：

1. 先按整行文本排一个**居中**「布局段落」，`getBoxesForRange`
   （`BoxHeightStyle.max`）取每个字/词在段落内的盒——自动换行、居中、shaping
   全部由它决定；
2. 每个字/词另排一个**左对齐**小段落，绘制时放到对应盒的原点，因此可以单独
   平移/缩放/加辉光。

按行缓存（键含文本/字体/字号/字重/宽度/颜色），只保留「激活行 + 淡出中的上一
激活行」（`LyricsFragmentCache.pruneTo`）。

### 3.2 羽化扫亮

当前正在唱的字/词：未唱变体打底 → `saveLayer` 画已唱变体 → 以 x 方向线性渐变
（α 1→0，过渡带宽 `wordFadeWidth×字号`）`dstIn` 裁切。已唱/未唱字直接用对应
变体，无额外图层。**每帧只有 1 层 `saveLayer`**（对比 P1 之前「每行每帧一层」）。

### 3.3 景深

- `blur`：**除高亮行外每一行都失焦**（对齐 AMLL `resolveBlurLevel`），两种画法
  （`LyricsBlurMode`）：
  - **`panel`（默认）**：所有非激活行画进**同一个** `saveLayer`，一次高斯，且在
    1/4 尺寸上做（`ImageFilter.compose` + `matrix` 降采样→模糊→放大，**无纹理缓存、
    不占显存**）。层数与可见行数无关，半径统一 σ=3。
  - **`perLine`**：逐行 `saveLayer + ImageFilter.blur`，σ = `min(5, 1 + 距离)`
    ——最贴上游的半径梯度，但每帧离屏层数 ≈ 可见行数。
  - **`lite`（轻量/近似）**：**不跑高斯**，把非激活行「放大 4% + 低透明」重绘一次
    做伪散焦（零离屏层，基准 7.7ms ≈ 无失焦的 6.3ms）。观感是重影式柔化，
    与上游高斯不同 —— 给吃不住任何高斯层的核显/软件光栅。
  - ⚠ 逐行档的 σ **不再折半**：CSS `blur(Xpx)` 的参数就是高斯 σ
    （Filter Effects 规范），AMLL 的 `blur(1+d)` 即 σ=2…5；早先实现误当半径
    折了 0.5，观感只有上游一半强度。
  - 另有收敛：**鼠标悬停时全部取消**（对齐 AMLL `.amll-lyric-player:hover … filter: unset`，
    方便悬停阅读与滚动）；`panel` 档以强度 0~1 平滑归零，不会「啪」地跳变。
- `scale` / `fade` / `blur` 都用**指数趋近**而不是给每行再挂弹簧：行数可达数百，
  逐行弹簧对象 + 逐帧求解不划算，且这三项是纯装饰量。
- 焦点行 = 激活行；无激活行（前奏/末尾/间奏）时用布局锚点，避免整墙瞬间变灰。
  

### 3.4 时钟

`LyricClock` 以「权威位置 + 本地累加时间」外推，位置/播放状态变化即重新锚定；
同一位置的重复上报不清空外推（配合上限，事件停更时停住）。`performanceMode`
（`animate=false`）下不推开时钟，回到事件驱动 + 直接吸附。

### 3.5 间奏

- 空隙起点 = 上一行**真实唱完**时间（有逐字时取字级结束时间，否则取
  `endMs`＝下一行起始 → 普通 LRC 不产生间奏，与 AMLL 一致）。
- 布局：间奏之后的行整体下移「三点 + 上下留白」，空隙本身成为三点位置；
  锚点停在间奏前一行。
- 间奏期间 `active = -1`（不高亮任何行，对齐 AMLL 清空高亮集合），三点做
  依次点亮 + 呼吸 + 两段式退场。

### 3.6 背景人声

整行被 `()`/`（）` 包裹即 `isBG`（对齐 AMLL `isBackgroundVocalText`），解析期
剥掉最外层括号（逐字行同步剥首尾片段）；该行不挂翻译/音译、字号 ×0.7、
透明度 ×0.4、**不占独立纵向槽位**（挂在最近主行下方，主行滚动时同步跟随）。

> ⚠ 重建 `LyricGroup` 的地方必须一并保留 `isBG`。目前有两处：
> `parseLyricGroups` 内部（行结束时间后置计算）与
> `services/lyrics/engine/lyric_pipeline.dart` 的 `UncensorLyricProcessor`
> （脏话还原）。后者是 main 的歌词引擎流水线，新增字段时容易漏。

### 3.7 排版度量（间距）

AMLL 的行距不是「行高 + gap」，而是由 `.lyricLineWrapper` 的
`padding: .4em`（上下各一颗）+ `line-height: 1.2` + 子行 `gap: .3em` 共同决定。
我们据此把度量统一为：

| 量 | 值 | AMLL 对应 |
|---|---|---|
| 主行行高 | `1.2 × 字号` | `.lyricLine` 继承 `line-height: 1.2` |
| 相邻行间距 | `0.8 × 字号` | wrapper 上下 `padding: .4em` |
| 主行↔子行间距 | `0.3 × 字号` | wrapper `gap: .3em` |
| 子行字号 | `max(0.5 × 字号, 10px)` | `.lyricSubLine` `max(.5em, 10px)` |
| 子行行高 | `1.5 × 子字号` | `.lyricSubLine` `line-height: 1.5em` |

**测量与绘制必须用同一组度量**：`computeLineHeights`（`TextPainter` 的
`height`）与 painter（`ui.ParagraphStyle`/`ui.TextStyle` 的 `height`）都按上表，
否则行高会与实际渲染漂移。

> 旧实现是「自然行高 + 0.42em 间距 + 0.05em 主↔译间距」，明显比 AMLL 紧，
> 且译文与主行几乎贴在一起；本轮统一到上表。注意 `kMainTranslationGapEm` /
> `kTranslationFontScale` 两个旧常量仍被**简单引擎 `LyricsView`** 使用，
> 不要混用。

### 3.8 换行弹簧（「高速换行不如 AMLL」的根因）

AMLL 正常播放**不用固定弹簧**，而是按当前行与上一行的时间差自适应
（`lyric-player/base/spring.ts`）：

- 间隔钳制 100~800ms → `ratio = 1 - (interval-100)/700` → `ratio^0.2`（五次方根，
  让 ratio 偏大 → 偏向更快）；
- `stiffness = 170 + ratio × 50`（间隔 100ms → 220，间隔 ≥800ms → 170）；
- `damping = √stiffness × 2.2` → **阻尼比 ζ≈1.1，略过阻尼、不过冲**；
- Seek / 间奏 → 慢速（90 / 15）；歌曲末尾 → 中速（140 / 22）；
- 质量固定 0.9。

我们原来的 `default` 预设是 `0.85 / 11 / 160`，**ζ≈0.47 的欠阻尼**：慢歌看着
「弹」，而高速换行（每行 300~500ms）时弹簧还没稳就换下一行，整墙一直在过冲
抖动——这正是「高速换行效果明显不如 AMLL」的原因。

因此 `default` 预设改为**自适应策略**（`kDefaultSpringPreset`），固定手感
（`smooth`/`responsive`/`jello`/`heavy`）保留给想手动覆盖的用户。

### 3.9 级联（stagger）与飞入
- **级联只在「播放推进换行」时启用**（对齐 `LayoutReason.PlaybackTick`）；
  Seek / 尺寸变化 / 首帧 / 重建一律不加延迟（`disableStagger`）。
- 级联累积规则对齐 AMLL：`if (y_i + height_i >= 0) { delay += 50ms; if (i >= anchor) delay /= 1.05 }`。
- 锚点跨屏跳转时仍然禁用级联（避免行距塌陷），这是我们的额外保护。
- **新歌/首帧整墙从视口下方飞入**（对齐 `RebuildView` 的 `resetPosition`），
  尺寸/字号变化则保留当前位置、由弹簧平滑过渡（对齐 `Resize`）。
- 触摸拖拽 `snapPosY`（1:1 跟手），滚轮走弹簧（对齐 `ContinuousScroll` / `DiscreteScroll`）。
- **高速换行不再吸附（2026-09-21 修正）**：原实现「间隔 ≤250ms 的单步换行直接吸附」
  已移除。AMLL 对换行**一律** `setTargetPosition`（保速弹簧 retarget），高速段靠
  「间隔越短刚度越高（→220）」追赶——不会硬切。我们改为同款：换行全部走弹簧
  （`_restart` 保留当前速度），仅 **seek / 拖拽 / 性能模式 / 禁用动画** 才硬切。
  （回归测试 `高速换行仍走弹簧（不硬切）` / `正常速度换行同样走弹簧` 各一。）
- **滚动预滚（对齐 AMLL `applyScrollPreroll`，2026-09-21）**：滚动锚点用**提前的**
  行起点——与前行无重叠提前 600ms（不早于上一组结束），对唱重叠提前 400ms
  （不早于前一行时长的 30%），背景行随主行。视野在开唱前先滚到位，高速换行时
  弹簧因此有提前量。**只影响滚动锚点**，高亮/逐字仍按原始行时间。

### 3.10 性能：只做视口内的工作（2026-09-20）
「屏幕只显示得下这么多行」是这一节所有优化的前提——不动的行不该参与每帧
计算，也不该为了一次字号/宽度变化就整首排版。

| 手段 | 做法 | 省掉的成本 |
|---|---|---|
| **行窗口** | 维持 `[_winStart, _winEnd)`：只有视口 ± 自适应余量（`max(视口高 × 0.6, 180px)`）内的行参与弹簧/过渡；边界按**行本体**（中心 ± 半高）判定，半可见的行也留在窗口内；窗口外 `Spring1D.park()`（**不重建求解器**，不参与每帧） | 换行时不再为全量行重建闭式解（原来每行 3 个闭包）；每帧循环从 O(歌长) 降到 O(视口) |
| **按需测量行高** | 视口外用 `estimateLineHeight()` 估算，进视口才 `computeLineHeight()` 实测；中心用 O(N) 纯算术重算 | 拖字号/改窗口宽度不再为整首逐行 `TextPainter.layout()` |
| **重绘抑制** | `_tick` 只在「弹簧在动 / 过渡在动 / 激活行有逐字片段（扫亮在推）/ 间奏三点可见」时才 `notify()` | 整行级歌词（无逐字）不再按 60fps 重绘整墙，只在位置事件（~20Hz）重绘 |
| **失焦（对齐上游）** | 除高亮行外**每一行**都失焦，两档：默认「整层一次 + 1/4 重采样」（1 个离屏层、像素量 1/4，半径统一 σ=4）；可切「逐行 σ=`min(5,1+距离)`」（最贴上游梯度）；悬停时全部取消 | 逐行档是本机基准里最贵的一项（900×600 场景：无失焦 6.3ms → 逐行 28.5ms）；整层 1/4 重采样降到 16.2ms 且层数恒定。见 `docs/player-render-optimization.md` §4.2 |
| **失焦档位可选（用户决定）** | `amll.blurQuality`：自动 / 流畅（整层）/ 轻量（零高斯伪散焦）/ 画质（逐行）/ 关闭；**显式档位不吃自动降级** | 机器差异太大（独显/核显/无 GPU），把权衡交给用户；自动档才带兜底 |
| **失焦自动降级** | 帧预算守卫（`LyricsBlurBudget`）：歌词墙在动时若连续多帧「光栅超 14ms 且 UI 线程正常」，就 latch 成关闭失焦（只降不升） | 不同机器（独显/核显/软件光栅/Windows Impeller）差一个数量级，编译期猜不出来；宁可不糊也不要卡 |
| **字体上限** | 字号可调范围 14–**60px**（原 38px 上限偏小） | — |

> 前置条件是 `Spring1D.park()`：视口外的行停在目标位置但**不重建求解器**
> （`_settled = true`，`update()/arrived()` 直接返回），等它进视口时再由
> `setTarget/hardSet` 按当时位姿重建——否则「窗口外不参与」会在重新进入时跳变。
>
> ⚠ `park()` 只停驻、不重建解算器，旧轨迹的 `_pos/_vel` 成为残值。必须用
> `_solverValid` 标记把它挡掉（停驻态初速度按 0 处理）：否则「倒带」后重新
> 入窗的行会把停驻前的速度注入新运动，冲过目标、叠到当前行上（表现为
> 「下方展示过的歌词在后方叠层/换行」）。回归测试见
> `test/lyrics_v7_spring_test.dart`（park 后 setTarget 不继承速度）与
> `test/lyrics_amll_engine_test.dart`（倒带后继续播放不叠行）。

### 3.11 交互：悬停取消失焦、拖动进度条高亮跟随

- **悬停取消失焦**：`MouseRegion` 进入歌词区时把窗口内各行的失焦目标设为 0，
  整层档与逐行档都按 `kBlurTau`（~0.22s）**平滑过渡**到 0，移出后同样平滑恢复
  （原实现为瞬切，观感生硬）。对齐 AMLL `:hover … filter: unset` 的意图——方便
  用户悬停阅读/滚动，但不做生硬的即时跳变。
- **拖动进度条时高亮跟随**：`PlayerLyricsBlock(dragMs:)` 在拖动期间用**拖动位置**
  驱动歌词（高亮与滚动跟手指），并冻结内部时钟（拖动位置是用户目标，不是播放
  推进，不能外推）。播放条那行当前歌词（`_ProgressLyric`）同样跟随。
  由于拖动位置是连续大跳变，会走 seek 路径（慢速弹簧、无级联）——
  高亮立刻跟上、整墙平滑滑过去，而不是瞬移。

---

## 4. 与上游的刻意差异 / 简化

| 项 | 差异 | 原因 |
|---|---|---|
| 颜色模型 | 保留 `playedColor`/`unplayedColor` 双色（上游单一 `--amll-lp-color` + 蒙版 α） | 既有用户设置与主题色联动；扫亮段用 played 色的 0.4/1.0，语义等价 |
| 非激活行透明度 | 距离渐淡 + 下限 `inactiveAlpha`（上游：动态词 1.0、非动态 0.2） | 双色模型下需要更明显的层次；仍可由设置调节 |
| 逐字变换粒度 | 以 `LyricFragment` 为单位（CJK 多为单字）；上游对强调词再拆 grapheme | 片段已经是字/词级，收益有限、复杂度显著 |
| 强调的作用范围 | 激活行内满足门槛的字符 | 与上游 `enable()` 只作用于高亮行一致 |
| 背景人声位置 | 恒在主行**下方**（上游按时间可上可下、带 80px 滑入） | 简化；滑入动画后续可加 |
| 上下边缘渐隐 | **未实现**（旧文档曾声称有） | AMLL 无此效果；景深已提供层次 |
| 手动浏览回归 | 除「下一行开始时 ≥500ms 未滚动」外，另保留 5s 无操作兜底 | 长间奏里不会把用户永久留在浏览态 |
| 弹簧预设 | 保留 `smooth/responsive/jello/heavy` 固定手感供覆盖 | 上游没有预设概念；`default` 已与上游一致 |
| 轻量档（`lite`） | 用「放大 4% + 低透明重绘」近似散焦，不是高斯模糊 | 零离屏层、成本几乎为零；给连 1 层高斯都吃不住的核显留一个「有景深但不卡」的选项，观感差异在文档与设置文案里写明 |
| 失焦半径分布（整层档） | `auto`/`fast` 档用**统一** σ=4，而不是上游的逐行梯度（σ 2→5） | 整层一次 = 层数恒定、成本可预测；半径梯度是次要成分（「除高亮行外都糊」才是主要成分）。σ 取中值偏上让悬停「模糊↔清晰」对比更明显。要梯度可在设置里选 `quality`（或 `ARCHOERA_LYRICS_BLUR=perline`） |
| 换行平衡 / ruby / 对唱 | 未实现 | 属数据模型/排版层，另立专项 |

---

## 5. 开关与成本

| 开关 | 默认 | 作用 |
|---|---|---|
| `lyrics.engine` | `simple` | `amll` 才启用本引擎（本轮未改默认） |
| `lyrics.fontSize` | `18`（14–**60**） | 字号上限提到 60px |
| `amll.blurQuality` | `auto` | 失焦档位：`auto` 自动（整层档起步 + 帧预算兜底）/ `fast` 流畅（固定整层档，1 层 + 1/4 重采样）/ `lite` 轻量（零高斯伪散焦，弱核显可用）/ `quality` 画质（固定逐行 σ=`min(5,1+距离)`，最贴上游、最吃 GPU）/ `off` 关闭。**显式档位不吃自动降级**（决定权交给用户）。旧键 `amll.enableBlur=false` 自动迁移为 `off` |
| `ARCHOERA_LYRICS_BLUR` | 未设 | 诊断/AB 用环境变量：`perline` / `panel` / `off`。显式指定时会**禁用自动降级**（便于对比真机手感） |
| `amll.enableScale` | `true` | 关掉非激活行缩放 |
| `amll.inactiveAlpha` | `0.45` | 非激活行透明度下限 |
| `amll.wordSweep` | `true` | 关掉后激活行走整行模式（无逐字） |
| `amll.alignFraction` | `0.5` | 激活行锚定位置 |
| `amll.springPreset` | `default` | 滚动弹簧手感 |
| `preset.performanceMode` | `false` | 吸附所有过渡、不推开时钟 |

**成本提醒**：本机（WSL、无 GPU、软件光栅）900×600 / 26 行 / 连续滚动的
headless 基准：无失焦 **6.3ms**、逐行失焦 **28.5ms**、整层 1/4 重采样 **16.2ms**
（明细见 `docs/player-render-optimization.md` §4.2）。也就是说**逐行档在弱机上
必然爆帧**——这正是默认改成整层档、并加「帧预算自动降级」的原因。
真机 GPU 上的绝对值会低很多，但「层数/像素量决定成本」这个排序不变；
`ARCHOERA_LYRICS_BLUR=perline|panel|off` 可在真机上直接对比。

---

## 6. 测试

- `test/lyrics_amll_engine_test.dart`：时钟外推/钳制/重锚、缓动曲线、
  间奏识别与三点动画、背景人声解析（含逐字剥括号）、逐字渲染几何与回退、
  **行纵向弹簧策略**（Seek/间奏/歌末/按间隔自适应/阻尼比 ζ≈1.1）、
  **排版度量**（间距常量、中心距、音译＋译文计入行高）、
  **罗马音与背景人声共存**（解析挂载、重建保留 `romaji`+`isBG`）、
  以及墙体行为（插值推进、淡入、缩放、按距离失焦、间奏期高亮清空、缓存有界、
  羽化扫亮像素级验证、音译行渲染、背景行不占槽位）。
- `test/lyrics_blur_budget_test.dart`：失焦档位解析（auto/fast/lite/quality/off 映射、
  显式档位不吃降级、环境变量覆盖优先级、`LyricsBlurQuality.parse`）与帧预算守卫
  （窗口未满不下结论、达阈值才降、UI 线程卡顿不计入）。
- `test/lyrics_prefs_test.dart`：`amll.blurQuality` 默认/写入/非法值回落/
  旧键 `amll.enableBlur=false` 迁移。
- `lyrics_amll_engine_test.dart` 另含：整层档为默认且强度收敛、悬停归零/恢复、
  强制逐行档仍按距离失焦、关闭档恒不失焦、轻量档伪散焦不抛异常、
  连续掉帧自动降级且只降不升、显式档位（流畅/轻量/画质）不吃降级。
- 既有回归：`test/lyrics_amll_engine_test.dart`（锚点 / seek / 换行弹簧（含高速不硬切）/
  滚动预滚 / 视口窗口 / 倒带）、`lyrics_v7_spring_test.dart`（含新度量下的行高断言）、
  `lyrics_paragraph_cache_test.dart`、`lyrics_view_test.dart`、
  `lyrics_engine_test.dart`（main 的引擎流水线 / 罗马音）全绿。

### 6.1 与 main 的合并注意（2026-09-20）

本工作最初基于 `ArchoeraOS` 分支（main 的下游、不回并 main），后发现
`origin/main` 已有「歌词引擎流水线 + 罗马音」改动，遂整体迁到
`feat/lyrics-amll-alignment`（基于 `origin/main`）并逐文件合并。要点：

- `LyricGroup.romaji`、`parseLyricGroups(romaji:)`、`LyricMatchResult.romaji`
  链路（`apis/lyric` → `engine/lyric_decoder`）、`showRomanization` 偏好
  （`prefs_player.dart`）全部保留；
- 排版/绘制顺序为 **音译在上、译文在下**，两者各自计入行高与离屏层范围；
- **新增 `LyricGroup` 字段时**，除了 `parseLyricGroups` 的行结束时间后置计算，
  还必须检查 `engine/lyric_pipeline.dart` 的 `UncensorLyricProcessor`
  （以及任何其它重建 `LyricGroup` 的位置）；
- 我们上一轮在旧 `stores/lyrics_provider.dart` 里加的 `isBG` 保留逻辑已失效
  （main 把后处理挪进了 `LyricPipeline`），改为在 `UncensorLyricProcessor` 中保留。
