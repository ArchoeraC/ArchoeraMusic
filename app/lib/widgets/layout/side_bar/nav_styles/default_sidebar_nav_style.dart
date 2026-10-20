// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 默认侧边栏高亮样式：每个导航项自带的静态指示条。
library;

import 'package:material_ui/material_ui.dart';

import 'sidebar_nav_style.dart';

/// 静态指示条（对齐 SMenu default 模式）。
///
/// 指示条由导航项内部绘制，因此不需要容器级指示条。
class DefaultSidebarNavStyle extends SidebarNavStyle {
  const DefaultSidebarNavStyle();

  @override
  String get id => 'default';

  @override
  bool get slidingIndicator => false;

  @override
  Widget? buildContainerIndicator({
    required BuildContext context,
    required Color color,
    required double left,
    required double top,
    required double height,
  }) => null;
}
