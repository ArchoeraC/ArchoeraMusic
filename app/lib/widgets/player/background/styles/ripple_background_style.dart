// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// `ripple`：水纹折射背景（[RippleBackground] 叠加在主题渐变上）。
library;

import 'package:material_ui/material_ui.dart';

import '../player_background_style.dart';
import '../ripple_background.dart';

class RippleBackgroundStyle extends PlayerBackgroundStyle {
  const RippleBackgroundStyle();

  @override
  String get id => 'ripple';

  @override
  Widget build(BuildContext context, PlayerBackgroundContext c) {
    if (!c.hasCover) return c.gradient;
    final ripple = c.ripple;
    return Stack(
      fit: StackFit.expand,
      children: [
        c.gradient,
        // RippleBackground 每帧画出不透明的预烘焙（模糊+饱和）封面，无需再叠
        // 一层 BlurredCover；其内部负责切歌双缓冲交叉淡化。
        RippleBackground(
          cover: c.cover,
          playing: c.playing,
          speed: ripple.speed,
          animate: ripple.animate,
          useShader: ripple.useShader,
          renderScale: ripple.renderScale,
          damageClippedDynamic: ripple.damageClippedDynamic,
          fallbackColor: Colors.transparent,
        ),
      ],
    );
  }
}
