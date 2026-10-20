// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 侧边栏导航高亮样式契约。
///
/// 高亮样式按模块拆分，通过注册表接入；新增样式不再修改
/// `side_bar_view.dart` 的字符串分支。
library;

import 'package:material_ui/material_ui.dart';

/// 一种侧边栏导航高亮样式。
abstract class SidebarNavStyle {
  const SidebarNavStyle();

  /// 偏好里的稳定 id（须登记到 `prefs_appearance.dart` 的
  /// `sidebarNavStyleIds`）。
  String get id;

  /// 是否由容器级滑动指示条接管高亮。
  ///
  /// 为 true 时导航项隐藏自身的静态指示条，改用
  /// [buildContainerIndicator] 构建的滑动条。
  bool get slidingIndicator;

  /// 构建叠在导航视口上的容器级指示条；静态样式返回 null。
  ///
  /// [left] / [top] / [height] 为选中导航项背景在导航容器坐标系中的
  /// 测量结果（由调用方负责测量与折叠/展开后的重测）。
  Widget? buildContainerIndicator({
    required BuildContext context,
    required Color color,
    required double left,
    required double top,
    required double height,
  });
}
