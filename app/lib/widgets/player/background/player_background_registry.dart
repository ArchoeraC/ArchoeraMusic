// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 播放页背景样式注册表。
///
/// 新增背景样式只需：
/// 1. 在 `styles/` 新建模块并实现 [PlayerBackgroundStyle]；
/// 2. 加进 [playerBackgrounds]；
/// 3. 在 `prefs_player.dart` 的 `playerBgTypes` 与设置页下拉里登记同一个 id；
/// 4. `test/player_background_registry_test.dart` 会守卫两处一致。
library;

import 'player_background_style.dart';
import 'styles/blur_background_style.dart';
import 'styles/cover_tone_background_style.dart';
import 'styles/fluid_background_style.dart';
import 'styles/gradient_background_style.dart';
import 'styles/ripple_background_style.dart';
import 'styles/solid_background_style.dart';

/// 内建背景样式（顺序仅用于注册表遍历）。
const List<PlayerBackgroundStyle> playerBackgrounds = <PlayerBackgroundStyle>[
  GradientBackgroundStyle(),
  BlurBackgroundStyle(),
  SolidBackgroundStyle(),
  RippleBackgroundStyle(),
  FluidBackgroundStyle(),
  CoverToneBackgroundStyle(),
];

final Map<String, PlayerBackgroundStyle> _backgroundsById =
    <String, PlayerBackgroundStyle>{
      for (final style in playerBackgrounds) style.id: style,
    };

/// id → 背景样式；未知 id 回退 `gradient`（旧数据/降级安全）。
PlayerBackgroundStyle playerBackgroundFor(String id) =>
    _backgroundsById[id] ?? _backgroundsById['gradient']!;
