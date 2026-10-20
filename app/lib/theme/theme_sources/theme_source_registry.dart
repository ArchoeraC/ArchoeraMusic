// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 主题色来源注册表。
///
/// 新增来源只需：
/// 1. 在 `theme_sources/` 新建模块并实现 [ThemeSourceStyle]；
/// 2. 加进 [themeSources]；
/// 3. 在 `prefs_appearance.dart` 的 `themeSourceIds` 登记同一个 id；
/// 4. `test/theme_appearance_registry_test.dart` 会守卫两处一致。
library;

import 'cover_theme_source.dart';
import 'custom_theme_source.dart';
import 'default_theme_source.dart';
import 'solid_theme_source.dart';
import 'theme_source_style.dart';

/// 内建主题色来源（顺序仅用于注册表遍历）。
const List<ThemeSourceStyle> themeSources = <ThemeSourceStyle>[
  DefaultThemeSource(),
  CustomThemeSource(),
  CoverThemeSource(),
  SolidThemeSource(),
];

final Map<String, ThemeSourceStyle> _sourcesById = <String, ThemeSourceStyle>{
  for (final source in themeSources) source.id: source,
};

/// id → 主题色来源；未知 id 回退 `default`（旧数据/降级安全）。
ThemeSourceStyle themeSourceStyleFor(String id) =>
    _sourcesById[id] ?? _sourcesById['default']!;
