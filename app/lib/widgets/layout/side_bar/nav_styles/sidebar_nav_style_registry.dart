// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 侧边栏导航高亮样式注册表。
///
/// 新增样式只需：
/// 1. 在 `nav_styles/` 新建模块并实现 [SidebarNavStyle]；
/// 2. 加进 [sidebarNavStyles]；
/// 3. 在 `prefs_appearance.dart` 的 `sidebarNavStyleIds` 登记同一个 id；
/// 4. `test/sidebar_nav_style_registry_test.dart` 会守卫两处一致。
library;

import 'animated_sidebar_nav_style.dart';
import 'default_sidebar_nav_style.dart';
import 'sidebar_nav_style.dart';

/// 内建侧边栏高亮样式（顺序仅用于注册表遍历）。
const List<SidebarNavStyle> sidebarNavStyles = <SidebarNavStyle>[
  DefaultSidebarNavStyle(),
  AnimatedSidebarNavStyle(),
];

final Map<String, SidebarNavStyle> _stylesById = <String, SidebarNavStyle>{
  for (final style in sidebarNavStyles) style.id: style,
};

/// id → 侧边栏高亮样式；未知 id 回退 `default`（旧数据/降级安全）。
SidebarNavStyle sidebarNavStyleFor(String id) =>
    _stylesById[id] ?? _stylesById['default']!;
