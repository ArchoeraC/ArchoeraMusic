// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 播放页「封面主色」背景（`coverTone`）。
///
/// 只画**一层**对角渐变：右下 = 封面主色压暗 10%，左上 = 主色提亮 20% 且
/// 色相 -30°（对齐 VutronMusic Classic 播放页的低对比主色背景）。不画封面
/// 图片、不做 blur / BackdropFilter，每帧只是一次矩形渐变填充。
///
/// 取色只发生在封面变化时（[playerCoverToneProvider] 内部带 LRU 缓存与竞态
/// token），组件本身只负责 400ms 左右的颜色过渡，绝不在 build 里解码图片。
///
/// 无封面 / 取色中 / 取色失败时回退到与 `PlayerBackground` 默认渐变**完全
/// 一致**的主题渐变（[playerDefaultBackgroundGradient]），不会出现空白。
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../theme/app_theme.dart';
import '../../../theme/cover_color.dart';

/// 暗端压暗比例（等价 CSS `brightness(0.9)`）。
const double kCoverToneDarken = 0.10;

/// 亮端提亮比例（等价 CSS `brightness(1.2)`）。
const double kCoverToneLighten = 0.20;

/// 亮端色相偏移（度，等价 CSS `hue-rotate(-30deg)`）。
const double kCoverToneHueShift = -30;

/// 切歌时的颜色过渡时长（对齐 `BlurredCover` 的交叉淡入节奏）。
const Duration kCoverToneTransition = Duration(milliseconds: 420);

double _clamp01(double v) => v.clamp(0.0, 1.0).toDouble();

/// 按比例缩放 RGB（等价 CSS `brightness()`，alpha 不变）。
Color _scaleRgb(Color color, double factor) => Color.from(
  alpha: color.a,
  red: _clamp01(color.r * factor),
  green: _clamp01(color.g * factor),
  blue: _clamp01(color.b * factor),
);

/// CSS/SVG `hue-rotate` 矩阵：只旋转色相，亮度（0.213R+0.715G+0.072B）不变。
///
/// 不用 HSV 旋转：HSV 在「橙 → 红」这类情况下感知亮度会明显下降，会让
/// 「亮端」比基色还暗、渐变明暗方向倒挂；矩阵法与上游 CSS 滤镜语义一致。
Color _rotateHue(Color color, double degrees) {
  final rad = degrees * math.pi / 180;
  final cosA = math.cos(rad);
  final sinA = math.sin(rad);
  final r = color.r;
  final g = color.g;
  final b = color.b;
  // 系数取自 SVG filter 规范的 hueRotate 矩阵。
  final rr =
      (0.213 + cosA * 0.787 - sinA * 0.213) * r +
      (0.715 - cosA * 0.715 - sinA * 0.715) * g +
      (0.072 - cosA * 0.072 + sinA * 0.928) * b;
  final gg =
      (0.213 - cosA * 0.213 + sinA * 0.143) * r +
      (0.715 + cosA * 0.285 + sinA * 0.140) * g +
      (0.072 - cosA * 0.072 - sinA * 0.283) * b;
  final bb =
      (0.213 - cosA * 0.213 - sinA * 0.787) * r +
      (0.715 - cosA * 0.715 + sinA * 0.715) * g +
      (0.072 + cosA * 0.928 + sinA * 0.072) * b;
  return Color.from(
    alpha: color.a,
    red: _clamp01(rr),
    green: _clamp01(gg),
    blue: _clamp01(bb),
  );
}

/// 由封面主色推导渐变两端色（纯函数，便于单测）：
/// - `dark`：基色压暗约 10%，铺在右下；
/// - `light`：基色提亮约 20% 后色相 -30°，铺向左上。
///
/// 灰色基色（饱和度为 0）旋转后仍是灰——不会凭空染色。
({Color dark, Color light}) coverToneColors(Color base) {
  final dark = _scaleRgb(base, 1 - kCoverToneDarken);
  final light = _rotateHue(
    _scaleRgb(base, 1 + kCoverToneLighten),
    kCoverToneHueShift,
  );
  return (dark: dark, light: light);
}

/// 封面主色 → 对角渐变（CSS `linear-gradient(to top left, dark, light)`）。
LinearGradient coverToneGradient(Color base) {
  final tone = coverToneColors(base);
  return LinearGradient(
    begin: Alignment.bottomRight,
    end: Alignment.topLeft,
    colors: [tone.dark, tone.light],
  );
}

/// 播放页默认背景渐变。
///
/// `PlayerBackground` 的 `gradient` 样式与本组件的兜底共用此函数，保证
/// 「没取到封面色」时与默认背景逐像素一致，不会因两处色值漂移而闪一下。
LinearGradient playerDefaultBackgroundGradient(BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  final chrome = Theme.of(context).extension<AppChromeColors>();
  return LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      scheme.primary.withValues(alpha: 0.28),
      chrome?.playerBackground ?? scheme.surface,
    ],
  );
}

/// 封面主色纯色/低对比渐变背景。
///
/// [cover] 为空、或取色尚未完成/失败时使用默认主题渐变；取到颜色后由
/// [AnimatedContainer] 平滑过渡（切歌、兜底 → 主色都不硬切）。
class CoverToneBackground extends ConsumerWidget {
  const CoverToneBackground({
    super.key,
    this.cover,
    this.duration = kCoverToneTransition,
  });

  /// 当前曲目封面地址（空表示无封面）。
  final String? cover;

  /// 颜色过渡时长。
  final Duration duration;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 只在封面变化时由 provider 重新取色；此处 watch 不会触发解码。
    final tone = ref.watch(playerCoverToneProvider);
    final hasCover = cover != null && cover!.isNotEmpty;
    final gradient = hasCover && tone != null
        ? coverToneGradient(tone)
        : playerDefaultBackgroundGradient(context);
    return AnimatedContainer(
      duration: duration,
      curve: Curves.easeInOut,
      decoration: BoxDecoration(gradient: gradient),
    );
  }
}
