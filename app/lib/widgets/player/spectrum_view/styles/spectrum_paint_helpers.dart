// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 频谱样式共享绘制工具：横向渐隐 shader 与波形包络绘制。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import 'spectrum_style.dart';

/// 横向渐隐 shader（对齐原 ShaderMask 的 [0,0.05,0.12,0.88,0.95,1] 停点，
/// 0x99/255≈0.6）。直接作为画笔 shader → 免去 ShaderMask 的离屏合成。
Shader spectrumFadeShader(Size size, Color base) {
  const stops = [0.0, 0.05, 0.12, 0.88, 0.95, 1.0];
  const alphas = [0.0, 0.6, 1.0, 1.0, 0.6, 0.0];
  return LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [for (final a in alphas) base.withValues(alpha: a)],
    stops: stops,
  ).createShader(Offset.zero & size);
}

/// 绘制平滑后的频谱包络曲线。
///
/// [mirror] 为 true 时上下各画一条（`wave`），false 时只画上半侧（`waveUp`）。
/// 两处调用除镜像外参数完全一致，故共享同一份绘制逻辑。
void paintSpectrumWave(
  Canvas canvas,
  Size size,
  SpectrumPaintContext c, {
  required bool mirror,
}) {
  final usableLen = c.usableLen;
  if (usableLen <= 1 || size.width <= 0) return;
  final midY = size.height / 2;
  final amp = math.max(size.height / 2 - 2, 1.0);
  final pad = math.min(16.0, size.width * 0.05);
  final curveWidth = size.width - 2 * pad;
  if (curveWidth <= 2) return;
  final stepX = curveWidth / (usableLen - 1);

  final smoothBins = Float64List(usableLen);
  for (var i = 0; i < usableLen; i++) {
    final lo = math.max(0, i - 1);
    final hi = math.min(usableLen - 1, i + 1);
    var sum = 0.0;
    var n = 0;
    for (var j = lo; j <= hi; j++) {
      final raw = c.stereo[j];
      sum += raw < 0 ? 0.0 : (raw > 1 ? 1.0 : raw);
      n++;
    }
    smoothBins[i] = sum / n;
  }

  const fadeLen = 12;
  for (var i = 0; i < fadeLen && i < usableLen; i++) {
    final k = i / fadeLen;
    smoothBins[i] *= k;
    final j = usableLen - 1 - i;
    if (j > i) {
      smoothBins[j] *= k;
    }
  }

  final paint = Paint()
    ..shader = spectrumFadeShader(size, c.color)
    ..style = PaintingStyle.stroke
    ..strokeWidth = math.max(1.5, math.min(3.0, c.barWidth))
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  void trace(Path path, double sign) {
    path.moveTo(pad, midY + sign * smoothBins[0] * amp);
    for (var i = 0; i < usableLen - 1; i++) {
      final y = midY + sign * smoothBins[i] * amp;
      final yMid =
          midY + sign * ((smoothBins[i] + smoothBins[i + 1]) / 2) * amp;
      path.quadraticBezierTo(pad + i * stepX, y, pad + (i + 0.5) * stepX, yMid);
    }
    path.lineTo(
      pad + (usableLen - 1) * stepX,
      midY + sign * smoothBins[usableLen - 1] * amp,
    );
  }

  final upper = Path();
  trace(upper, -1);
  canvas.drawPath(upper, paint);
  if (mirror) {
    final lower = Path();
    trace(lower, 1);
    canvas.drawPath(lower, paint);
  }
}
