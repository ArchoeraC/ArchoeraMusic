// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 毛玻璃模糊的共用包装（性能模式降级 + 共享模糊输入）。
///
/// 正常模式：套一层 [BackdropFilter]（对齐原版 `backdrop-filter` 语义）。
/// 性能模式（`AppPrefs.performanceMode`）：**不创建模糊离屏 pass**，直接
/// 返回 [child] —— 调用方的 child 本身即同色半透明底 / 边框 / 阴影，故
/// 布局、圆角、颜色与动画完全不变，仅背景不再模糊。
///
/// 共享模糊输入（[backdropIsBakedBlur]）：调用方**保证**本面板背后只有
/// 「已预烘焙的模糊背景」（图片风格的壳层背景是一次性烘焙的模糊壁纸，
/// 且无任何动态内容穿过面板背后，如停靠模式的内容层已为播放条让位）。
/// 此时毛玻璃的模糊输入直接复用背景烘焙的那一次高斯——对已模糊图像再
/// 做 σ16 高斯在视觉上近乎无差，却要每帧付整条离屏 pass，故直接免掉。
/// child 需自带半透明底（或传 [tint]），半透明底透出模糊背景即毛玻璃观感。
///
/// 若 child 自身没有底色，可传 [tint] 作为降级时的纯半透明填充
/// （当前 7 处调用点的 child 均自带半透明底，无需 tint）。
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
    this.backdropIsBakedBlur = false,
  });

  /// 高斯模糊半径（正常模式；性能模式下忽略）。
  final double sigma;

  /// 玻璃面板内容（应自带同色半透明底，性能模式下即由其承担填充）。
  final Widget child;

  /// 可选的降级底色；仅当 child 无自带底色时使用，性能模式下叠加于 child 之下。
  final Color? tint;

  /// 背后只有预烘焙的模糊背景（无动态内容穿过）时置 true：复用背景烘焙的
  /// 那一次模糊（共享模糊输入），不创建 [BackdropFilter]。见库注释。
  final bool backdropIsBakedBlur;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reduced = ref.watch(
      appPrefsProvider.select((p) => p.performanceMode),
    );
    if (!reduced && !backdropIsBakedBlur) {
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
