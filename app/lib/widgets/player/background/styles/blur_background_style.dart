// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// `blur`：封面重度模糊背景（[BlurredCover] 内部负责切歌交叉淡化）。
library;

import 'package:material_ui/material_ui.dart';

import '../blurred_cover.dart';
import '../player_background_style.dart';

class BlurBackgroundStyle extends PlayerBackgroundStyle {
  const BlurBackgroundStyle();

  @override
  String get id => 'blur';

  @override
  Widget build(BuildContext context, PlayerBackgroundContext c) {
    if (!c.hasCover) return c.gradient;
    return BlurredCover(cover: c.cover!);
  }
}
