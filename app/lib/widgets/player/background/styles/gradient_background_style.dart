// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// `gradient`：主题主色 → 播放器底色的对角渐变（默认兜底）。
library;

import 'package:material_ui/material_ui.dart';

import '../player_background_style.dart';

class GradientBackgroundStyle extends PlayerBackgroundStyle {
  const GradientBackgroundStyle();

  @override
  String get id => 'gradient';

  @override
  Widget build(BuildContext context, PlayerBackgroundContext c) => c.gradient;
}
