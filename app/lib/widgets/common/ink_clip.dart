// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 将子树的 InkWell ink（悬停 overlay / 水波纹）裁剪到自身范围。
///
/// 背景：Flutter 的 ink 由**最近的 [Material]** 绘制，**不经滚动视口裁剪**——
/// 于是半露出视口的列表行，其悬停高亮会越界画到列表上下边界之外（纵向溢出）。
/// 给滚动列表套一层本组件（透明 Material + 裁剪），即可把 ink 裁回视口内；
/// 不影响列表布局与滚动，水波纹仍保留，只是不再越界。
library;

import 'package:material_ui/material_ui.dart';

class InkClip extends StatelessWidget {
  const InkClip({super.key, required this.child, this.borderRadius});

  final Widget child;

  /// 需要圆角裁剪（如对话框内列表）时传入；null = 矩形裁剪。
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      clipBehavior: Clip.hardEdge,
      shape: borderRadius == null
          ? null
          : RoundedRectangleBorder(borderRadius: borderRadius!),
      child: child,
    );
  }
}
