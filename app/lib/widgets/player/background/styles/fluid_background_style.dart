// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// `fluid`：流体网格背景（[FluidBackground] 叠加在主题渐变上）。
library;

import 'package:material_ui/material_ui.dart';

import '../fluid_background.dart';
import '../player_background_style.dart';

class FluidBackgroundStyle extends PlayerBackgroundStyle {
  const FluidBackgroundStyle();

  @override
  String get id => 'fluid';

  @override
  Widget build(BuildContext context, PlayerBackgroundContext c) {
    if (!c.hasCover) return c.gradient;
    final fluid = c.fluid;
    return Stack(
      fit: StackFit.expand,
      children: [
        c.gradient,
        FluidBackground(
          cover: c.cover,
          playing: c.playing,
          animate: fluid.animate,
          flowSpeed: fluid.flowSpeed,
          renderScale: fluid.renderScale,
          fps: fluid.fps,
          freezeOnPause: fluid.freezeOnPause,
          beat: fluid.beat,
        ),
      ],
    );
  }
}
