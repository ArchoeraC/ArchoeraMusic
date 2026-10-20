// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:material_ui/material_ui.dart';

import 'theme_source_style.dart';

/// 跟随系统主题色（读取失败时由调用方回退默认亮蓝）。
class DefaultThemeSource extends ThemeSourceStyle {
  const DefaultThemeSource();

  @override
  String get id => 'default';

  @override
  Color? accentSeed(ThemeSourceContext context) => context.systemAccent;

  @override
  bool get usesSystemAccent => true;
}
