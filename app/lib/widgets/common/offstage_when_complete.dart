// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/widgets.dart';

/// 动画完成（value ≥ [threshold]）后用 [Offstage] 停绘 [child]。
///
/// 用途：被上层不透明内容**完全遮挡**的大面积层（如播放页展开后的壳层
/// 内容 / 背景 / 停靠播放条——`/player` 路由是 `opaque: false`，壳层仍会被
/// 绘制），停绘可省掉每帧的全屏重放；`Offstage` 保留 element/state，返回时
/// 无需重建，不会闪烁。子树内动画同时由 [TickerMode] 暂停，避免被遮挡期间
/// 空转。对应调研里的「遮挡显式隐藏」
/// （见 `docs/rendering-reference-research.md` D6）。
///
/// 只监听 [animation]，不监听无关的父级重建；动画逐帧推进时仅重建本包装
/// 的 [Offstage] / [TickerMode] 属性，[child] 通过 `child` 参数原样传递、
/// 不重建。
class OffstageWhenComplete extends StatelessWidget {
  const OffstageWhenComplete({
    super.key,
    required this.animation,
    required this.child,
    this.threshold = 0.999,
  });

  /// 驱动动画（0 = 折叠，1 = 完全展开）。
  final Animation<double> animation;

  final Widget child;

  /// 视为「完成」的阈值（避免浮点 1.0 抖动；默认 0.999）。
  final double threshold;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: animation,
      builder: (context, child) {
        final hidden = animation.value >= threshold;
        return Offstage(
          offstage: hidden,
          child: TickerMode(enabled: !hidden, child: child!),
        );
      },
      child: child,
    );
  }
}
