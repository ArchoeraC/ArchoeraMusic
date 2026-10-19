// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:material_ui/material_ui.dart';

import 'theme_source_style.dart';

/// 从当前播放曲目封面取色（实时跟随；未取到时回退默认亮蓝）。
class CoverThemeSource extends ThemeSourceStyle {
  const CoverThemeSource();

  @override
  String get id => 'cover';

  @override
  Color? accentSeed(ThemeSourceContext context) => context.coverAccent;

  @override
  bool get usesCoverAccent => true;
}
