// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// `solid`：深色纯色背景。
library;

import 'package:material_ui/material_ui.dart';

import '../player_background_style.dart';

/// 纯色背景色值（与旧实现一致）。
const Color playerSolidBackgroundColor = Color(0xFF141420);

class SolidBackgroundStyle extends PlayerBackgroundStyle {
  const SolidBackgroundStyle();

  @override
  String get id => 'solid';

  @override
  Widget build(BuildContext context, PlayerBackgroundContext c) =>
      const ColoredBox(color: playerSolidBackgroundColor);
}
