// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/widgets.dart';

/// 全屏播放器展开时主壳内容的收起/展开动效，并在完全展开后**真正卸载**
/// 壳内容（释放列表/图片内存），仅保留轻量 [placeholder]。
///
/// 对齐原版 MainLayout 根容器：
/// `transition-[transform,opacity] duration-500 ease-[cubic-bezier(0.7,0,0.3,1)]`
/// + 目标 `scale-95 opacity-0 pointer-events-none`。
///
/// 语义：
///  - 折叠态（默认）：直接渲染 [child]（scale 1 / opacity 1，不包
///    [IgnorePointer]），与不使用本组件时逐帧一致；
///  - 展开：child 播放 scale 1→0.95 + opacity 1→0，**动画完成后**切换到
///    [placeholder]，此时 child 从树上移除；
///  - 收起：立即切回 child（保证进入动画有内容），再反向播放动画；
///  - [disableAnimations]（性能模式）：不做动画，展开直切 placeholder、
///    折叠直切 child。
///
/// 本组件不读取任何 provider / [MediaQuery]；[disableAnimations] 由调用方
/// 显式传入，以便脱离应用独立做 widget 测试。
class ShellExpandTransition extends StatefulWidget {
  const ShellExpandTransition({
    super.key,
    required this.expanded,
    required this.child,
    required this.placeholder,
    this.duration = const Duration(milliseconds: 500),
    this.curve = const Cubic(0.7, 0, 0.3, 1),
    this.disableAnimations = false,
  });

  /// 是否展开（true → 收起并最终卸载壳内容）。
  final bool expanded;

  /// 壳内容（展开动画完成后会被卸载）。
  final Widget child;

  /// 完全展开后展示的轻量占位（不应包含列表/图片）。
  final Widget placeholder;

  /// 动画时长。
  final Duration duration;

  /// 动画曲线。
  final Curve curve;

  /// 性能模式：跳过动画，直切目标态。
  final bool disableAnimations;

  @override
  State<ShellExpandTransition> createState() => _ShellExpandTransitionState();
}

class _ShellExpandTransitionState extends State<ShellExpandTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: widget.duration,
  );
  late final Animation<double> _driver = _ctrl.drive(
    CurveTween(curve: widget.curve),
  );
  late final Animation<double> _scale = Tween<double>(
    begin: 1,
    end: 0.95,
  ).animate(_driver);
  late final Animation<double> _opacity = Tween<double>(
    begin: 1,
    end: 0,
  ).animate(_driver);

  /// 当前是否展示 placeholder（true 时 [ShellExpandTransition.child]
  /// 已从树上移除）。
  bool _placeholder = false;

  @override
  void initState() {
    super.initState();
    // 初始挂载不播动画：展开直接 placeholder，折叠直接 child。
    _placeholder = widget.expanded;
    _ctrl.value = widget.expanded ? 1 : 0;
    _ctrl.addStatusListener(_onStatus);
  }

  void _onStatus(AnimationStatus status) {
    // 仅在展开动画结束后卸载 child，避免动画途中内容消失。
    if (status == AnimationStatus.completed &&
        widget.expanded &&
        !_placeholder) {
      setState(() => _placeholder = true);
    }
  }

  @override
  void didUpdateWidget(covariant ShellExpandTransition old) {
    super.didUpdateWidget(old);
    _ctrl.duration = widget.duration;
    if (old.expanded == widget.expanded &&
        old.disableAnimations == widget.disableAnimations) {
      return;
    }
    if (widget.disableAnimations) {
      _ctrl.stop();
      _ctrl.value = widget.expanded ? 1 : 0;
      setState(() => _placeholder = widget.expanded);
      return;
    }
    if (widget.expanded) {
      _ctrl.forward();
    } else {
      // 收起：立即切回 child，保证反向动画（内容淡入）有内容可渲染。
      setState(() => _placeholder = false);
      _ctrl.reverse();
    }
  }

  @override
  void dispose() {
    _ctrl.removeStatusListener(_onStatus);
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.disableAnimations) {
      return widget.expanded ? widget.placeholder : widget.child;
    }
    if (_placeholder) return widget.placeholder;
    // 折叠静止态不加任何包裹，保持与未使用本组件时一致。
    if (_ctrl.value == 0) return widget.child;
    Widget result = ScaleTransition(
      scale: _scale,
      child: FadeTransition(opacity: _opacity, child: widget.child),
    );
    if (widget.expanded) result = IgnorePointer(child: result);
    return result;
  }
}
