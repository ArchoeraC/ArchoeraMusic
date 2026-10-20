// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// `waveUp`：包络曲线只向基线一侧（上）延伸，无镜像。
library;

import 'package:material_ui/material_ui.dart';

import 'spectrum_paint_helpers.dart';
import 'spectrum_style.dart';

class WaveUpSpectrumStyle extends SpectrumStyleRenderer {
  const WaveUpSpectrumStyle();

  @override
  String get id => 'waveUp';

  @override
  void paint(Canvas canvas, Size size, SpectrumPaintContext c) =>
      paintSpectrumWave(canvas, size, c, mirror: false);
}
