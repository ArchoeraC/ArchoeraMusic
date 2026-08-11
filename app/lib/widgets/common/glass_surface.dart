/// 图片风格下的玻璃弹层容器（对齐原版 global.css 弹层毛玻璃语义：
/// `[role="dialog"] backdrop-filter: blur(16px) saturate(1.4)`）。
///
/// 用法：把弹窗的 `backgroundColor` 设为 `Colors.transparent`，将弹窗内容
/// 包进本组件——图片风格下提供半透明底 + 背景模糊（背景图不再清晰透出，
/// 可读性对齐非图片风格）；非图片风格直接实底，两模式视觉一致且无 blur 开销。
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../stores/app_prefs.dart';

class GlassDialogSurface extends ConsumerWidget {
  const GlassDialogSurface({
    super.key,
    required this.radius,
    required this.color,
    required this.child,
  });

  /// 弹窗圆角（与弹窗 shape 一致，blur 只在圆角内生效）。
  final BorderRadius radius;

  /// 弹窗底色（非图片风格 = 面板实底；图片风格 = 半透明面板色）。
  final Color color;

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(appPrefsProvider);
    final imageStyle =
        prefs.appearanceStyle == 'image' && prefs.backgroundImage != null;
    // 非图片风格：实底面板 + 圆角裁剪（变暗由弹窗外 barrier 承担，
    // 弹窗本体保持与图片风格一致的实底可读性；圆角由本容器裁剪，
    // Dialog 侧配合 clipBehavior 保证画布也被裁剪，不出现直角溢出）。
    if (!imageStyle) {
      return ClipRRect(
        borderRadius: radius,
        child: ColoredBox(color: color, child: child),
      );
    }
    return ClipRRect(
      borderRadius: radius,
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: ColoredBox(color: color, child: child),
      ),
    );
  }
}
