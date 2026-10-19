// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// `wave`：镜像对称的频谱包络曲线，形似声波。
library;

import 'package:material_ui/material_ui.dart';

import 'spectrum_paint_helpers.dart';
import 'spectrum_style.dart';

class WaveSpectrumStyle extends SpectrumStyleRenderer {
  const WaveSpectrumStyle();

  @override
  String get id => 'wave';

  @override
  void paint(Canvas canvas, Size size, SpectrumPaintContext c) =>
      paintSpectrumWave(canvas, size, c, mirror: true);
}
