// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:archoera_music/eta/mark/eta_mark.dart';

/// 应用 Logo（白标）：圆角方块底 + 品牌标识（均衡器频谱）。
///
/// 提取自侧边栏顶部品牌区（对齐 SideBarLogo.vue）：完全跟随全局主题
/// 对比色——底 primaryContainer、标 onPrimaryContainer；尺寸由 [size]
/// 驱动，圆角/图标按比例缩放，保证各处观感一致。
/// 中央图形为品牌标识独立字体族 EtaMark.brand（源 logo-trim.png，见 app/eta-tools/eta_mark/）。
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 30});

  /// Logo 边长（含底块）；默认 30（侧边栏尺寸）。
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(size * 0.3),
      ),
      child: Icon(
        EtaMark.brand,
        size: size * 0.6,
        color: scheme.onPrimaryContainer,
      ),
    );
  }
}
