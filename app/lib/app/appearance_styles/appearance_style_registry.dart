// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 外观风格注册表。
///
/// 新增风格只需：
/// 1. 在 `appearance_styles/` 新建模块并实现 [AppearanceStyle]；
/// 2. 加进 [appearanceStyles]；
/// 3. 在 `prefs_appearance.dart` 的 `appearanceStyleIds` 登记同一个 id；
/// 4. `test/theme_appearance_registry_test.dart` 会守卫两处一致。
library;

import 'appearance_style.dart';
import 'image_appearance_style.dart';
import 'solid_appearance_style.dart';

/// 内建外观风格（顺序仅用于注册表遍历）。
const List<AppearanceStyle> appearanceStyles = <AppearanceStyle>[
  SolidAppearanceStyle(),
  ImageAppearanceStyle(),
];

final Map<String, AppearanceStyle> _stylesById = <String, AppearanceStyle>{
  for (final style in appearanceStyles) style.id: style,
};

/// id → 外观风格；未知 id 回退 `solid`（旧数据/降级安全）。
AppearanceStyle appearanceStyleFor(String id) =>
    _stylesById[id] ?? _stylesById['solid']!;
