// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// `coverTone`：封面主色派生的低对比对角渐变（取色失败回退主题渐变）。
library;

import 'package:material_ui/material_ui.dart';

import '../cover_tone_background.dart';
import '../player_background_style.dart';

class CoverToneBackgroundStyle extends PlayerBackgroundStyle {
  const CoverToneBackgroundStyle();

  @override
  String get id => 'coverTone';

  @override
  Widget build(BuildContext context, PlayerBackgroundContext c) {
    // 取色本身有默认渐变兜底；无封面时直接返回渐变，省掉一层组件。
    if (!c.hasCover) return c.gradient;
    return CoverToneBackground(cover: c.cover);
  }
}
