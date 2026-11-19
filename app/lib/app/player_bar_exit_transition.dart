// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/widgets.dart';

import 'player_route_curves.dart';

/// 播放条让出进度：0 = 完全可见，1 = 已滑出屏幕底部。
///
/// 只取路由动画的前 [kPlayerBarPhase] 段：展开时播放条在这段里滑出，之后
/// 页面上滑；收起时路由动画反向递减，这段落最后 → 播放条最后回位（倒序）。
/// 前后两段共用同一条 `easeInCubic` 形状：正放是「越走越快」地让开，反放
/// 则变成「先快后慢」地落位（`transform` 直接作用在递减值上，不做 flipped，
/// 与 `ShellExpandTransition` 的 reverseCurve 约定一致）。
double playerBarExitProgress(double routeValue) {
  final raw = (routeValue / kPlayerBarPhase).clamp(0.0, 1.0);
  return Curves.easeInCubic.transform(raw);
}

/// 播放页展开 / 收起时，底部播放条的让出与回位动效。
///
/// 本组件只做**渲染**，不改路由时序：`/player` 仍由
/// `PlayerRouteController` 立即 push/pop，播放页的转场用 `Interval` 让出
/// 前段（见 `router.dart`），两条时间线共用同一条路由动画，天然同帧同步、
/// 不会出现「播放条还没让开页面就开始上滑」的竞态。
///
/// 与 `AnimatedSwitcher`（播放条自身「有无曲目」的显隐）互不干扰：那个是
/// 内容层显隐，这里是整条让路。
class PlayerBarExitTransition extends StatelessWidget {
  const PlayerBarExitTransition({
    super.key,
    required this.animation,
    required this.child,
    this.disableAnimations = false,
  });

  /// 驱动动画（0 = 折叠，1 = 完全展开；播放页路由自身动画）。
  final Animation<double> animation;

  final Widget child;

  /// 性能模式：路由没有转场，播放页第一帧就整幅盖住播放条，无需再演滑出。
  final bool disableAnimations;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: animation,
      builder: (context, child) {
        final hidden = disableAnimations
            ? 0.0
            : playerBarExitProgress(animation.value);
        return IgnorePointer(
          // 让出过程中不再截获点击（下面露出的壳内容仍是活的）。
          ignoring: hidden > 0.001,
          child: Opacity(
            opacity: (1 - hidden).clamp(0.0, 1.0),
            child: FractionalTranslation(
              // 平移自身高度：滑出窗口底部被 Stack 裁掉（`clipBehavior`
              // 默认 hardEdge），与 `AnimatedSwitcher` 的 translate-y-full 同构。
              translation: Offset(0, hidden),
              child: child,
            ),
          ),
        );
      },
      child: child,
    );
  }
}
