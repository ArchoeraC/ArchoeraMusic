// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 毛玻璃模糊的共用包装（性能模式降级）。
///
/// 正常模式：套一层 [BackdropFilter]（对齐原版 `backdrop-filter` 语义）。
/// 性能模式（`AppPrefs.performanceMode`）：**不创建模糊离屏 pass**，直接
/// 返回 [child] —— 调用方的 child 本身即同色半透明底 / 边框 / 阴影，故
/// 布局、圆角、颜色与动画完全不变，仅背景不再模糊。
///
/// 若 child 自身没有底色，可传 [tint] 作为降级时的纯半透明填充。
library;

import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../stores/app_prefs.dart';

class GlassBlur extends ConsumerWidget {
  const GlassBlur({
    super.key,
    required this.sigma,
    required this.child,
    this.tint,
  });

  /// 高斯模糊半径（正常模式；性能模式下忽略）。
  final double sigma;

  /// 玻璃面板内容（应自带同色半透明底，性能模式下即由其承担填充）。
  final Widget child;

  /// 可选的降级底色；仅当 child 无自带底色时使用，性能模式下叠加于 child 之下。
  final Color? tint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reduced = ref.watch(
      appPrefsProvider.select((p) => p.performanceMode),
    );
    if (!reduced) {
      return BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: child,
      );
    }
    final fallback = tint;
    if (fallback == null) return child;
    return ColoredBox(color: fallback, child: child);
  }
}
