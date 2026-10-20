// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:material_ui/material_ui.dart';

import 'theme_source_style.dart';

/// 纯色中性色板（无主题色种子，主/次色用灰阶）。
class SolidThemeSource extends ThemeSourceStyle {
  const SolidThemeSource();

  @override
  String get id => 'solid';

  @override
  Color? accentSeed(ThemeSourceContext context) => null;

  @override
  bool get solid => true;
}
