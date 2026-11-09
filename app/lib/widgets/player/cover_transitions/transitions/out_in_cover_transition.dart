// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// scale / slide 共用的 out-in 状态机：旧封面先离场，结束后换图再入场。
library;

import 'package:material_ui/material_ui.dart';

import '../../../common/anim.dart';

/// out-in 切换器。
///
/// 离场与入场两段动画不重叠（对齐 Vue `mode="out-in"`）：
/// - [slide] 为 false 时做位移 + 缩放 + 淡入淡出；
/// - [slide] 为 true 时做全幅滑动，方向跟随 [next]（下一首从右进、向左出，
///   上一首相反）。
/// 离场曲线 [Curves.ease]，入场曲线 [Curves.easeOutExpo]；时长由
/// [leaveDuration] / [enterDuration] 指定。系统关闭动画时直接换图。
class OutInCoverTransition extends StatefulWidget {
  const OutInCoverTransition({
    super.key,
    required this.coverKey,
    required this.next,
    required this.slide,
    required this.leaveDuration,
    required this.enterDuration,
    required this.child,
    this.shift = 10,
    this.leaveScale = 1,
    this.enterScale = 1,
  });

  /// 封面身份（切歌即变化，触发切换动效）。
  final Object coverKey;

  /// 切歌方向（true = 下一首）。
  final bool next;

  /// 是否使用全幅滑动；否则为位移 + 缩放 + 淡入淡出。
  final bool slide;

  final Duration leaveDuration;
  final Duration enterDuration;

  /// 非滑动样式的水平位移幅度（px）。
  final double shift;

  /// 旧封面离场时的终态缩放（>1 = 轻微放大）。
  final double leaveScale;

  /// 新封面入场时的起始缩放（<1 = 从略小处放大）。
  final double enterScale;

  final Widget child;

  @override
  State<OutInCoverTransition> createState() => _OutInCoverTransitionState();
}

class _OutInCoverTransitionState extends State<OutInCoverTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  Widget _shown = const SizedBox.shrink();
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    _shown = widget.child;
    _ctrl = AnimationController(vsync: this, duration: widget.enterDuration)
      ..addStatusListener(_onStatus);
  }

  @override
  void didUpdateWidget(OutInCoverTransition old) {
    super.didUpdateWidget(old);
    if (widget.coverKey == old.coverKey) return;
    if (noAnim(context)) {
      _ctrl.stop();
      _leaving = false;
      _shown = widget.child;
      return;
    }
    _leaving = true;
    _ctrl.duration = widget.leaveDuration;
    _ctrl.forward(from: 0);
  }

  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || !_leaving) return;
    _leaving = false;
    setState(() => _shown = widget.child);
    _ctrl.duration = widget.enterDuration;
    _ctrl.forward(from: 0);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final t = _ctrl.value;
        final posT = _leaving
            ? Curves.ease.transform(t)
            : Curves.easeOutExpo.transform(t);
        final opT = Curves.ease.transform(t);
        return LayoutBuilder(
          builder: (context, c) {
            final width = c.maxWidth;
            final double dx;
            final double opacity;
            final double scale;
            if (_leaving) {
              final dir = widget.next ? -1.0 : 1.0;
              dx = widget.slide ? dir * width * posT : -widget.shift * posT;
              opacity = 1 - opT;
              scale = 1 + (widget.leaveScale - 1) * posT;
            } else if (_ctrl.isAnimating) {
              final dir = widget.next ? 1.0 : -1.0;
              dx = widget.slide
                  ? dir * width * (1 - posT)
                  : widget.shift * (1 - posT);
              opacity = opT;
              scale = widget.enterScale + (1 - widget.enterScale) * posT;
            } else {
              dx = 0;
              opacity = 1;
              scale = 1;
            }
            return Opacity(
              opacity: opacity.clamp(0.0, 1.0),
              child: Transform.translate(
                offset: Offset(dx, 0),
                child: Transform.scale(
                  scale: scale,
                  child: (!_leaving && !_ctrl.isAnimating)
                      ? widget.child
                      : _shown,
                ),
              ),
            );
          },
        );
      },
    );
  }
}
