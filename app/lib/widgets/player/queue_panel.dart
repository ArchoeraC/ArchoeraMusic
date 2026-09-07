// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/netease/track.dart';
import '../../services/playback/playback_notifier.dart';
import '../../l10n/l10n.dart';
import '../../utils/format.dart';
import '../list/cover_image.dart';
import 'package:archoera_music/eta/icon/eta_icons.dart';

part 'queue_panel/queue_panel_view.dart';

/// 播放列表面板展示模式。
enum QueuePanelStyle {
  /// 右侧滑入侧边栏（播放页用）：面板贴窗口右缘、撑满高度。
  slide,

  /// 锚定浮层（播放条用）：从触发按钮位置紧凑展开，
  /// 动效对齐顶栏账号 PopupMenuButton（淡入 + 轻微弹性放大）。
  popup,
}

/// 播放列表面板（对齐原项目队列；从播放条 / 播放页打开）。
///
/// 展示当前播放队列：当前曲高亮、点击切换、移除、拖拽排序；
/// 顶部提供随机 / 循环模式切换与清空。
/// 交互：毛玻璃面板；播放页走右侧滑入，播放条走锚定浮层。
class QueuePanel extends ConsumerWidget {
  const QueuePanel({
    super.key,
    required this.style,
    required this.width,
    required this.animation,
    this.anchor,
    this.maxHeight,
  });

  /// 展示模式（[QueuePanelStyle.slide] / [QueuePanelStyle.popup]）。
  final QueuePanelStyle style;

  /// 面板锚点（overlay 坐标：left / bottom），popup 模式由 [show] 计算。
  final Offset? anchor;

  /// 面板宽度。
  final double width;

  /// 面板最大高度（popup 模式，避免超出窗口顶边）。
  final double? maxHeight;

  /// 路由入场动画（面板本体的动效在此实现，而非作用于全屏）。
  final Animation<double> animation;

  static Future<void> show(
    BuildContext context, {
    QueuePanelStyle style = QueuePanelStyle.slide,
    Rect? anchor,
  }) {
    final overlaySize =
        (Overlay.of(context).context.findRenderObject() as RenderBox?)?.size ??
        MediaQuery.sizeOf(context);
    const width = 400.0;
    const gap = 8.0; // popup：面板底边到触发按钮顶边的间距
    const margin = 12.0;

    final slide = style == QueuePanelStyle.slide;
    final a = anchor;
    // slide：右缘贴窗口；popup：右缘对齐按钮（窗口边界自动收敛）
    final left = slide
        ? overlaySize.width - width - margin
        : a == null
        ? overlaySize.width - width - margin
        : (a.right - width)
              .clamp(margin, overlaySize.width - width - margin)
              .toDouble();
    // slide：全高留上下边距；popup：从按钮顶部向上展开
    final bottom = slide
        ? margin
        : a == null
        ? 96.0
        : (overlaySize.height - a.top + gap)
              .clamp(margin, overlaySize.height - width)
              .toDouble();
    final maxHeight = (overlaySize.height - margin - bottom)
        .clamp(240.0, 560.0)
        .toDouble();

    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: context.l10n.queueTitle,
      // slide（侧边栏）：变暗遮罩；popup：透明遮罩，点击面板外关闭
      // （对齐 PopupMenuButton：无遮罩变暗，点外部即收起）
      barrierColor: slide
          ? Colors.black.withValues(alpha: 0.35)
          : Colors.transparent,
      // 与「更多」PopupMenuButton 同款时长（_kMenuDuration）
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (context, animation, secondaryAnimation) => QueuePanel(
        style: style,
        anchor: Offset(left, bottom),
        width: width,
        maxHeight: maxHeight,
        animation: animation,
      ),
      // 面板动效在 QueuePanel 内部实现（作用面板本体，对齐「更多」菜单：
      // 原地淡入 + 弹性放大，而非整屏动画）
      transitionBuilder: (context, animation, secondaryAnimation, child) =>
          child,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      _buildQueuePanel(context, ref);
}
