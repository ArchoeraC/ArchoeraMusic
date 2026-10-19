// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:material_ui/material_ui.dart';

import '../../stores/app_prefs.dart';
import 'appearance_style.dart';

/// 纯色外观：不渲染图片背景层。
class SolidAppearanceStyle extends AppearanceStyle {
  const SolidAppearanceStyle();

  @override
  String get id => 'solid';

  @override
  bool get usesImageBackground => false;

  @override
  bool effectiveImageBackground(AppPrefs prefs) => false;

  @override
  Widget? buildBackground(BuildContext context, AppPrefs prefs) => null;
}
