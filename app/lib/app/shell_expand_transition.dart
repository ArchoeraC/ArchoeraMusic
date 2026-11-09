// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/widgets.dart';

import '../theme/motion.dart';

/// 全屏播放器展开时主壳内容的收起/展开动效。
///
/// **不再卸载壳内容**。此前在展开完成后把整个壳（列表 / 图片 / 页面 State）
/// 从树上移除，返回时重建：表面/图层/驱动缓存只涨不缩，实测每次进出都会让
/// RSS 与原生堆增长，重建成本也高于保持挂载。现在只做两件事：
///  - 展开过程：scale 1→0.95 + opacity 1→0（与播放页滑动同一条曲线）；
///  - 完全展开后：用 [Offstage] **停绘 + 停布局**，并用 [TickerMode] 暂停
///    壳内动画；element/state 全部保留，收起时立即恢复，无重建闪烁。
///
/// 注意：返回的控件树**顶层类型必须稳定**（始终是 Offstage → TickerMode →
/// Opacity → Transform）。如果展开态换成另一套包装，Flutter 会因为顶层类型
/// 变化而重建整棵子树，滚动位置 / 页面 State 依然会丢。
class ShellExpandTransition extends StatelessWidget {
  const ShellExpandTransition({
    super.key,
    required this.animation,
    required this.child,
    this.curve = appMotion,
    this.disableAnimations = false,
  });

  /// 驱动动画：0 = 折叠，1 = 展开（播放页路由自身动画）。
  final Animation<double> animation;

  /// 壳内容（始终保留在树上）。
  final Widget child;

  /// 动画曲线（与播放页滑动保持一致）。
  final Curve curve;

  /// 性能模式：跳过动画，直切目标态。
  final bool disableAnimations;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: animation,
      builder: (context, child) {
        final raw = animation.value.clamp(0.0, 1.0);
        // 反向动画的第一帧值仍可能 ≥0.999：此时必须立刻恢复显示，否则
        // 收起会慢半拍（旧实现用状态监听在 reverse 时立即切回 child）。
        final reversing = animation.status == AnimationStatus.reverse;
        final t = disableAnimations
            ? (raw >= 1 ? 1.0 : 0.0)
            : curve.transform(raw);
        final expanded = t >= 0.999 && !reversing;
        return Offstage(
          offstage: expanded,
          child: TickerMode(
            enabled: !expanded,
            child: Opacity(
              opacity: (1 - t).clamp(0.0, 1.0),
              child: Transform.scale(scale: 1 - 0.05 * t, child: child),
            ),
          ),
        );
      },
      child: child,
    );
  }
}
