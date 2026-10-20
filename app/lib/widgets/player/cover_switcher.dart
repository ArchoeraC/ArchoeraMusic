// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 封面切换动效入口：解析偏好 id，委托 `cover_transitions/` 注册表。
///
/// 切歌（封面 [coverKey] 变化）时按 [style] 播放：
/// - scale（默认）：旧封面先离场、新封面再入场（Vue `mode="out-in"`，
///   两段动画不重叠），轻微缩放 + 位移 + 淡入淡出；
/// - slide：同样 out-in，全幅滑动（对齐 slide-edge），方向跟随播放顺序：
///   下一首新封面从右进、旧封面向左出；上一首相反；
/// - fade：新旧封面双层交叉淡化，仅改透明度，不做位移或缩放。
///
/// 时长/曲线：scale 离场 0.2s ease / 入场 0.35s easeOutExpo；
/// slide 离场 0.35s ease / 入场 0.4s easeOutExpo
/// （`cubic-bezier(0.16,1,0.3,1)` 即 Flutter [Curves.easeOutExpo]）；
/// fade 两层各 0.36s easeInOutCubic。
///
/// 新增动效只需实现 `CoverTransition` 并登记到 [coverTransitions]，
/// 本组件不再维护样式分支。
library;

import 'package:material_ui/material_ui.dart';

import 'cover_transitions/cover_transition.dart';
import 'cover_transitions/cover_transition_registry.dart';

class CoverSwitcher extends StatelessWidget {
  const CoverSwitcher({
    super.key,
    required this.coverKey,
    required this.style,
    required this.next,
    required this.child,
  });

  /// 封面身份（切歌即变化，触发切换动效）。
  final Object coverKey;

  /// 偏好里的动效 id（见 `transitionStyles`；未知回退 `scale`）。
  final String style;

  /// 切歌方向（true = 下一首，新封面从右进；仅 `slide` 使用）。
  final bool next;

  final Widget child;

  @override
  Widget build(BuildContext context) => coverTransitionFor(style).build(
    context,
    CoverTransitionContext(coverKey: coverKey, next: next, child: child),
  );
}
