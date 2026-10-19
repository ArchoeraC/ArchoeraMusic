// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 播放页背景样式契约与只读上下文。
///
/// 背景样式按模块拆分，通过注册表接入；新增样式不再修改
/// `player_background.dart` 的渲染分支。
library;

import 'package:material_ui/material_ui.dart';

/// 水纹背景参数快照（由 `PlayerBackground` 从偏好解析）。
class RippleBackgroundConfig {
  const RippleBackgroundConfig({
    required this.speed,
    required this.animate,
    required this.useShader,
    required this.damageClippedDynamic,
    required this.renderScale,
  });

  final double speed;
  final bool animate;
  final bool useShader;
  final bool damageClippedDynamic;
  final double renderScale;
}

/// 流体背景参数快照。
class FluidBackgroundConfig {
  const FluidBackgroundConfig({
    required this.animate,
    required this.flowSpeed,
    required this.renderScale,
    required this.fps,
    required this.freezeOnPause,
    required this.beat,
  });

  final bool animate;
  final double flowSpeed;
  final double renderScale;
  final int fps;
  final bool freezeOnPause;
  final bool beat;
}

/// 背景构建所需的只读快照。
class PlayerBackgroundContext {
  const PlayerBackgroundContext({
    required this.cover,
    required this.playing,
    required this.hasCover,
    required this.gradient,
    required this.ripple,
    required this.fluid,
  });

  /// 当前曲目封面地址。
  final String? cover;

  /// 是否正在播放（水纹/流体暂停行为）。
  final bool playing;

  /// 是否有可用封面；无封面时多数样式回退 [gradient]。
  final bool hasCover;

  /// 默认主题渐变（无封面兜底，也供实现复用）。
  final Widget gradient;

  final RippleBackgroundConfig ripple;
  final FluidBackgroundConfig fluid;
}

/// 一种播放页背景样式。
abstract class PlayerBackgroundStyle {
  const PlayerBackgroundStyle();

  /// 偏好里的稳定 id（须登记到 `playerBgTypes`）。
  String get id;

  /// 构建背景；无封面/降级由实现自行回退 [PlayerBackgroundContext.gradient]。
  Widget build(BuildContext context, PlayerBackgroundContext c);
}
