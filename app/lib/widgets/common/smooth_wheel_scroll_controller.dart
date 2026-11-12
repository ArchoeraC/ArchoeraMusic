// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// 给列表的**滚轮 / 触控板滚动**补一段短时缓动（对齐歌词页滚轮的手感）。
///
/// 只接管 `ScrollPosition.pointerScroll`（鼠标滚轮、触控板滚动信号）：
/// - **触摸拖拽**走 `drag()`，**键盘**走 `ScrollAction`，都不经过这里，行为不变；
/// - 用 `animateTo` 驱动，拖拽会自然接管并中断动画（`DrivenScrollActivity`
///   被拖拽活动替换），不会出现「手在拖、动画还在抢位置」。
///
/// 为什么不直接搬歌词页的弹簧：歌词是逐行 `Spring1D + Ticker + forcePixels`，
/// 需要自己处理拖拽打断、边界夹取、活动状态通知；列表改用 `ScrollPosition`
/// 自带的驱动式动画更稳，观感（快速趋近 + 缓停）与 AMLL `DiscreteScroll`
/// 的过阻尼弹簧一致。
class SmoothWheelScrollController extends ScrollController {
  SmoothWheelScrollController({
    super.initialScrollOffset,
    super.keepScrollOffset,
    super.debugLabel,
  });

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _SmoothWheelScrollPosition(
    physics: physics,
    context: context,
    initialPixels: initialScrollOffset,
    keepScrollOffset: keepScrollOffset,
    oldPosition: oldPosition,
    debugLabel: debugLabel,
  );
}

class _SmoothWheelScrollPosition extends ScrollPositionWithSingleContext {
  _SmoothWheelScrollPosition({
    required super.physics,
    required super.context,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
  });

  /// 单次滚轮事件的动画时长下限 / 上限。
  static const Duration minDuration = Duration(milliseconds: 70);
  static const Duration maxDuration = Duration(milliseconds: 180);

  /// 位移 → 时长换算（毫秒 / 像素）：约 100px/档 ⇒ 110ms。
  static const double _msPerPixel = 1.1;

  @override
  void pointerScroll(double delta) {
    // 触控板「惯性取消」事件（delta == 0）：交给基类收尾。
    if (delta == 0.0) {
      super.pointerScroll(delta);
      return;
    }
    final double target = math.min(
      math.max(pixels + delta, minScrollExtent),
      maxScrollExtent,
    );
    if (target == pixels) return;

    final BuildContext? ctx = context.notificationContext;
    // 性能模式（MediaQuery.disableAnimations）：保持原生瞬时滚动。
    if (ctx != null && (MediaQuery.maybeDisableAnimationsOf(ctx) ?? false)) {
      super.pointerScroll(delta);
      return;
    }

    final int ms = ((target - pixels).abs() * _msPerPixel)
        .clamp(
          minDuration.inMilliseconds.toDouble(),
          maxDuration.inMilliseconds.toDouble(),
        )
        .round();
    // 连续滚轮会不断重定目标：新的 animateTo 从**当前**位置续上，形成连贯滑动。
    // 返回的 Future 无需等待（被下一次滚动或拖拽打断都属正常）。
    // ignore: discarded_futures
    animateTo(
      target,
      duration: Duration(milliseconds: ms),
      curve: Curves.easeOutCubic,
    );
  }
}
