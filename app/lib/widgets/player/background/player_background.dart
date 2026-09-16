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

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
            // 模糊封面背景（与 blur 档共用）；水纹纹理未就绪/失败时透出。
            BlurredCover(cover: cover!),
            RippleBackground(
              cover: cover,
              playing: playing,
              speed: prefs.playerBgRippleSpeed,
              animate: !prefs.performanceMode,
              fallbackColor: Colors.transparent,
            ),
          ],
        );
      default:
        return gradient;
    }
  }
}
