// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 滑动高亮样式：容器级指示条随选中项平滑移动。
library;

import 'package:material_ui/material_ui.dart';

import '../../../common/anim.dart';
import 'sidebar_nav_style.dart';

/// 滑动指示条（对齐 SMenu animated 模式）。
class AnimatedSidebarNavStyle extends SidebarNavStyle {
  const AnimatedSidebarNavStyle();

  @override
  String get id => 'animated';

  @override
  bool get slidingIndicator => true;

  @override
  Widget? buildContainerIndicator({
    required BuildContext context,
    required Color color,
    required double left,
    required double top,
    required double height,
  }) => AnimatedPositioned(
    duration: animDuration(context, const Duration(milliseconds: 250)),
    curve: Curves.easeOut,
    // 对齐 SMenu animated：left 跟随选中项左缘；top/height
    // 上下各内缩 10px，与静态模式（Positioned top:10/bottom:10）一致
    left: left,
    top: top + 10,
    height: height - 20,
    width: 3,
    child: IgnorePointer(
      child: Container(
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    ),
  );
}
