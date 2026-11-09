# 全应用动效节奏：近线性（Motion System）

> 状态：**已实施（2026-11-09）**。
> 范围：全应用 UI 动效——路由转场、播放页展开、侧栏 / 播放条 / 弹窗、
> 歌词滚动、封面切换、背景交叉淡入、Toast、音量渐变等。
> 关联：[player-render-optimization.md](player-render-optimization.md)、
> [runtime-resource-optimization.md](runtime-resource-optimization.md)。

## 1. 为什么改

旧代码大量使用 `easeOutCubic` / `easeOutExpo` / `easeOutBack`：

- **起步极快**：大位移（播放页 500ms 全屏上滑、页面切换、队列面板）在前
  100~150ms 就走完大半，视觉上像「窜出去」；
- **收尾极慢**：最后 30% 距离耗时接近一半，用户会感觉「怎么还没停」；
- **过冲**：`easeOutBack` 会先越过目标再弹回，和「线性阅读 / 拖动」的直觉冲突。

参考 Material / Carbon / Figma 的动效指南，可以归纳为两条：

1. **透明度、颜色、音量、连续滚动、进度**：用线性。人眼对这几类量没有
   「速度故事」，缓动反而制造不必要的不均匀。
2. **位置 / 形变 / 进出场**：需要轻微的加减速，但不应有强 ease-out 的
   「先冲后爬」，更不应过冲。贝塞尔控制点应靠近对角线。

## 2. 令牌

`app/lib/theme/motion.dart`：

```dart
/// 位置 / 形变 / 转场：近线性、无过冲。
const Curve appMotion = Cubic(0.2, 0.2, 0.8, 0.8);

/// 透明度 / 颜色 / 音量 / 滚动 / 进度：线性。
const Curve appMotionLinear = Curves.linear;
```

`Cubic(0.2, 0.2, 0.8, 0.8)` 的两端斜率都是 1（与线性首尾速度一致），中段
只做极轻的平滑；因此大位移不会「猛起步」，收尾也不会「爬半天」。

## 3. 使用规则

| 场景 | 用哪个 |
|---|---|
| 路由转场、播放页展开、侧栏 / 播放条 / 队列面板、弹窗、Toast 位移 | `appMotion` |
| 歌词换行滚动、跑马灯、卡拉 OK 跟随、进度 / 音量 | `appMotionLinear` |
| `AnimatedOpacity` / `FadeTransition` / 颜色插值 / 背景交叉淡化 | `appMotionLinear` |
| 性能模式（`MediaQuery.disableAnimations`） | 时长归零（`animDuration`），曲线无关 |

- 不再新增 `easeOutBack` / `easeOutExpo` / `easeOutCubic` 等强缓动；
  需要「进入 / 退出」差异时优先用**时长与位移**表达，而不是换曲线。
- `Curves.linear` 保留给连续量；位置动画不要直接用 `Curves.linear` 做
  大幅进出场（端点速度突变会显得生硬）——用 `appMotion`。

## 4. 已覆盖的位置

- `app_theme.dart` 页面转场、`router.dart` 播放页上下滑、`ShellExpandTransition`；
- `route_transitions/`（fade / slide / zoom）；
- 侧栏折叠、播放条显隐、队列面板、搜索下拉、Toast、登录弹窗；
- 播放页 chrome 淡入淡出、背景交叉淡入、封面切换、悬停音量；
- 歌词简单引擎（滚动 / 扫亮）与 bar 迷你歌词；
- 音量渐变（线性，避免淡入淡出听感忽快忽慢）。

## 5. 回归

曲线本身不改变布局/状态语义，现有 widget 测试全部保持绿；歌词重写的
视口/排版缓存回归见 `test/lyrics_view_rebuild_test.dart`。
