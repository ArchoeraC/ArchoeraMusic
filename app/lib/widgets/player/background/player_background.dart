// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 全屏播放器背景。
///
/// 背景样式走注册表（[playerBackgrounds]），模块位于 `styles/`：
/// - `gradient`：主题主色 → 播放器底色的对角渐变（默认，兜底）；
/// - `blur`：封面重度模糊背景（`blur(45px) saturate(1.2)` + 放大 + 压暗）；
/// - `solid`：深色纯色；
/// - `ripple`：模糊封面 + 水纹折射（`RippleBackground` 叠加其上）；
/// - `fluid`：流体背景（`FluidBackground`，对齐上游 AMLL `MeshGradientRenderer`）；
/// - `coverTone`：封面主色压暗/提亮的低对比对角渐变。
///
/// 切换背景样式时通过 [CrossFadeSwitcher] 做 200ms 交叉淡化（对齐封面
/// `fade` 动效），不再硬切；`blur` / `ripple` 内部的切歌交叉淡化保持不变。
/// 无封面时大部分样式回退主题渐变。
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/render/quality_governor.dart';
import '../../../services/render/render_quality_service.dart';
import '../../../stores/app_prefs.dart';
import '../../common/cross_fade_switcher.dart';
import 'cover_tone_background.dart';
import 'player_background_registry.dart';
import 'player_background_style.dart';

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
    final gradient = DecoratedBox(
      decoration: BoxDecoration(
        gradient: playerDefaultBackgroundGradient(context),
      ),
    );
    final hasCover = cover != null && cover!.isNotEmpty;
    final style = playerBackgroundFor(prefs.playerBgType);
    final animate = !prefs.performanceMode;
    return CrossFadeSwitcher(
      switchKey: style.id,
      child: style.build(
        context,
        PlayerBackgroundContext(
          cover: cover,
          playing: playing,
          hasCover: hasCover,
          gradient: gradient,
          ripple: RippleBackgroundConfig(
            speed: prefs.playerBgRippleSpeed,
            animate: animate,
            useShader: prefs.rippleShaderEnabled,
            damageClippedDynamic: prefs.rippleDamageClip,
            renderScale: renderScale,
          ),
          fluid: FluidBackgroundConfig(
            animate: animate,
            flowSpeed: prefs.playerBgFlowSpeed,
            renderScale: prefs.playerBgRenderScale,
            fps: prefs.playerBgFps,
            freezeOnPause: prefs.playerBgFreezeOnPause,
            beat: prefs.playerBgBeat,
          ),
        ),
      ),
    );
  }
}
