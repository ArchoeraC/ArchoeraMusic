// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 播放页右侧歌词槽：管理歌词的显隐动效与组件生命周期。
///
/// - 打开：自下而上滑入（`begin = (0, 1)` → `0`）；
/// - 关闭：**向下滑出**，动画结束后**卸载**歌词组件（[builder] 不再被调用）；
/// - 性能模式（`MediaQuery.disableAnimations`）：直切，关闭即卸载。
///
/// 只负责显隐 / 动效 / 生命周期，不关心歌词来源与样式（由 [builder] 决定）；
/// [ClipRect] 裁切滑出过程，避免溢出到下方控制区。
library;

import 'package:material_ui/material_ui.dart';

import '../common/anim.dart';

/// 歌词显隐槽（见库注释）。
class PlayerLyricsSlot extends StatefulWidget {
  const PlayerLyricsSlot({
    super.key,
    required this.visible,
    required this.enabled,
    required this.builder,
    this.duration = const Duration(milliseconds: 480),
  });

  /// 用户是否开启歌词（`showLyricsInPlayer`）。
  final bool visible;

  /// 当前是否具备展示条件（有歌词，且播放页进入动画已结束）。false 立即隐藏。
  final bool enabled;

  /// 构建歌词内容（仅在需要展示 / 滑出时调用；隐藏时不构建）。
  final WidgetBuilder builder;

  /// 滑入 / 滑出时长（性能模式下归零）。
  final Duration duration;

  @override
  State<PlayerLyricsSlot> createState() => _PlayerLyricsSlotState();
}

class _PlayerLyricsSlotState extends State<PlayerLyricsSlot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: widget.duration,
    value: (widget.visible && widget.enabled) ? 1 : 0,
  );

  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, 1),
    end: Offset.zero,
  ).animate(
    CurvedAnimation(
      parent: _ctrl,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    ),
  );

  @override
  void initState() {
    super.initState();
    // 滑出结束（dismissed）后重建一次 → 卸载歌词组件。
    _ctrl.addStatusListener((status) {
      if (status == AnimationStatus.dismissed && mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(PlayerLyricsSlot oldWidget) {
    super.didUpdateWidget(oldWidget);
    final target = widget.visible && widget.enabled;
    final prev = oldWidget.visible && oldWidget.enabled;
    if (target == prev) return;
    _ctrl.duration = animDuration(context, widget.duration);
    if (target) {
      _ctrl.forward();
    } else {
      _ctrl.reverse();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final animated = !noAnim(context);
    final target = widget.visible && widget.enabled;
    // 目标可见，或正在滑出（动画尚未归零）→ 构建；归零后卸载。
    final show = target || (animated && _ctrl.value > 0);
    if (!show) return const SizedBox.shrink();
    return ClipRect(
      child: IgnorePointer(
        ignoring: !target,
        child: SlideTransition(
          position: _slide,
          child: widget.builder(context),
        ),
      ),
    );
  }
}
