// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 全屏播放器背景。
///
/// 支持四种样式（设置 → 播放 → 播放页背景）：
/// - `gradient`：主题主色 → 播放器底色的对角渐变（默认，兜底）；
/// - `blur`：封面重度模糊背景（`blur(45px) saturate(1.2)` + 放大 + 压暗）；
/// - `solid`：深色纯色；
/// - `ripple`：模糊封面（[BlurredCover]）+ 水纹折射（[RippleBackground] 叠加其上，
///   对齐上游 `.bg-blur-wrap` + ripple canvas 的分层结构）。
///
/// 无封面时 blur / ripple 均回退渐变。
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/render/quality_governor.dart';
import '../../../services/render/render_quality_service.dart';
import '../../../stores/app_prefs.dart';
import '../../../theme/app_theme.dart';
import 'blurred_cover.dart';
import 'ripple_background.dart';

/// 全屏播放器背景。[cover] 为当前曲目封面地址；[playing] 透传给水纹动画。
class PlayerBackground extends ConsumerWidget {
  const PlayerBackground({super.key, this.cover, this.playing = true});

  final String? cover;
  final bool playing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(appPrefsProvider);
    // 自适应画质仅在偏好开启且 Governor 已降档时生效；否则 renderScale=1.0
    // 与省略该参数逐字节一致（见 RippleBackground.renderScale）。
    final qualityTier = ref.watch(renderQualityProvider);
    final adaptiveScale =
        prefs.adaptiveRenderQuality && qualityTier != RenderQualityTier.full
        ? renderScaleForTier(qualityTier)
        : 1.0;
    // 手动「动态层降分辨率」（仅 CPU 回退生效）与自适应画质取更激进者。
    final renderScale = prefs.rippleLowRes
        ? math.min(rippleLowResScale, adaptiveScale)
        : adaptiveScale;
    final scheme = Theme.of(context).colorScheme;
    final chrome = Theme.of(context).extension<AppChromeColors>();
    final gradient = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            scheme.primary.withValues(alpha: 0.28),
            chrome?.playerBackground ?? scheme.surface,
          ],
        ),
      ),
    );
    final hasCover = cover != null && cover!.isNotEmpty;

    switch (prefs.playerBgType) {
      case 'solid':
        return const ColoredBox(color: Color(0xFF141420));
      case 'blur':
        if (!hasCover) return gradient;
        return BlurredCover(cover: cover!);
      case 'ripple':
        if (!hasCover) return gradient;
        return Stack(
          fit: StackFit.expand,
          children: [
            gradient,
            // 不再叠 BlurredCover：RippleBackground 每帧画出**不透明**的预烘焙
            // （模糊+饱和）封面，完全覆盖其下任何模糊层；此前那层全屏
            // ImageFiltered(sigma45) 纯属每帧重算的浪费（Impeller 无图层缓存）。
            RippleBackground(
              cover: cover,
              playing: playing,
              speed: prefs.playerBgRippleSpeed,
              animate: !prefs.performanceMode,
              useShader: prefs.rippleShaderEnabled,
              renderScale: renderScale,
              damageClippedDynamic: prefs.rippleDamageClip,
              fallbackColor: Colors.transparent,
            ),
          ],
        );
      default:
        return gradient;
    }
  }
}
