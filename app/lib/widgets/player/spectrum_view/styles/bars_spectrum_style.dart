// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// `bars`：经典条形（双声道镜像、底部对齐、圆角柱）。
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'spectrum_paint_helpers.dart';
import 'spectrum_style.dart';

class BarsSpectrumStyle extends SpectrumStyleRenderer {
  const BarsSpectrumStyle();

  /// 相邻 bar 的间隙（px，与旧实现一致）。
  static const int barGap = 3;

  static const double _minBarHeight = 0.5;

  @override
  String get id => 'bars';

  @override
  void paint(Canvas canvas, Size size, SpectrumPaintContext c) {
    final usableLen = c.usableLen;
    final slotWidth = c.barWidth + barGap;
    final numBars = (size.width / slotWidth).floor();
    if (numBars <= 0) return;

    // 单 Path 批量提交（替代 N 次 drawRRect）；横向渐隐由画笔 shader 承担，
    // 不再需要 widget 侧 ShaderMask 离屏层。
    final path = Path();
    for (var i = 0; i < numBars; i++) {
      final startBin = (i * usableLen / numBars).floor();
      final endBin = ((i + 1) * usableLen / numBars).floor();
      final lo = math.max(0, startBin - 1);
      final hi = math.min(usableLen, math.max(endBin, startBin + 1) + 1);
      var sum = 0.0;
      for (var j = lo; j < hi; j++) {
        sum += c.stereo[j];
      }
      final v = sum / (hi - lo);
      final barHeight = v * size.height;
      if (barHeight <= _minBarHeight) continue;
      path.addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            i * slotWidth,
            size.height - barHeight,
            c.barWidth,
            barHeight,
          ),
          Radius.circular(c.radius),
        ),
      );
    }
    if (path.getBounds().isEmpty) return;
    canvas.drawPath(path, Paint()..shader = spectrumFadeShader(size, c.color));
  }
}
