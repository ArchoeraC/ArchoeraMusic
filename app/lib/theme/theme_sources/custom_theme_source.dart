// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:material_ui/material_ui.dart';

import '../../stores/app_prefs.dart';
import 'theme_source_style.dart';

/// 自定义主色（未设置时回退默认亮蓝）。
class CustomThemeSource extends ThemeSourceStyle {
  const CustomThemeSource();

  @override
  String get id => 'custom';

  @override
  Color? accentSeed(ThemeSourceContext context) => context.prefs.accentColor;

  @override
  bool get allowsCustomAccent => true;
}
