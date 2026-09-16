// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/widgets.dart';

/// 全屏播放器展开时主壳内容的收起/展开动效，并在完全展开后**真正卸载**
/// 壳内容（释放列表/图片内存），仅保留轻量 [placeholder]。
///
/// 动画由传入的 [animation]（播放页路由自身的动画，0 = 折叠、1 = 完全展开）
/// 驱动，并套用与播放页滑动**同一条曲线** [curve]，保证两侧节奏一致、有韧性。
/// 该动画由播放页路由的 Ticker 逐帧推进，壳层无需自建 Ticker——从而绕开
/// 「下方路由被 Overlay 置为 offstage 时自建 Ticker 不逐帧推进」的问题。
///
/// 语义：
///  - 折叠（≈0）：直接渲染 [child]（scale 1 / opacity 1），与不使用本组件时
///    逐帧一致；
///  - 展开：child 播放 scale 1→0.95 + opacity 1→0；**动画完成后**切换到
///    [placeholder]，此时 child 从树上移除（卸载）；
///  - 收起：立即切回 child，随后随动画反向恢复；
///  - [disableAnimations]（性能模式）：不做动画，展开直切 placeholder、
///    折叠直切 child。
class ShellExpandTransition extends StatefulWidget {
  const ShellExpandTransition({
    super.key,
    required this.animation,
    required this.child,
    required this.placeholder,
    this.curve = const Cubic(0.7, 0, 0.3, 1),
    this.disableAnimations = false,
  });

  /// 驱动动画：0 = 折叠，1 = 展开（播放页路由自身动画）。
  final Animation<double> animation;

  /// 壳内容（展开动画完成后会被卸载）。
  final Widget child;

  /// 完全展开后展示的轻量占位（不应包含列表/图片）。
  final Widget placeholder;

  /// 动画曲线（与播放页滑动保持一致）。
  final Curve curve;

  /// 性能模式：跳过动画，直切目标态。
  final bool disableAnimations;

  @override
  State<ShellExpandTransition> createState() => _ShellExpandTransitionState();
}

class _ShellExpandTransitionState extends State<ShellExpandTransition> {
  /// 当前是否展示 placeholder（true 时 child 已从树上移除）。
  bool _placeholder = false;

  late CurvedAnimation _curved;

  @override
  void initState() {
    super.initState();
    _curved = _makeCurved();
    _placeholder = widget.disableAnimations && _curved.value >= 1;
    widget.animation.addStatusListener(_onStatus);
    widget.animation.addListener(_onValue);
  }

  CurvedAnimation _makeCurved() => CurvedAnimation(
    parent: widget.animation,
    curve: widget.curve,
    reverseCurve: widget.curve,
  );

  @override
  void didUpdateWidget(covariant ShellExpandTransition old) {
    super.didUpdateWidget(old);
    if (!identical(old.animation, widget.animation) ||
        old.curve != widget.curve) {
      old.animation.removeStatusListener(_onStatus);
      old.animation.removeListener(_onValue);
      _curved.dispose();
      _curved = _makeCurved();
      widget.animation.addStatusListener(_onStatus);
      widget.animation.addListener(_onValue);
    }
  }

  /// 性能模式下无 Ticker 动画，需在 animation 值变化时刷新占位态。
  void _onValue() {
    if (!widget.disableAnimations) return;
    final shouldPlaceholder = _curved.value >= 1;
    if (shouldPlaceholder != _placeholder) {
      setState(() => _placeholder = shouldPlaceholder);
    }
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed &&
        widget.animation.value >= 1 &&
        !_placeholder) {
      // 展开动画结束 → 卸载壳内容。
      setState(() => _placeholder = true);
    } else if (status == AnimationStatus.reverse && _placeholder) {
      // 播放页开始收起 → 立即恢复壳内容，随后随动画反向展开。
      setState(() => _placeholder = false);
    }
  }

  @override
  void dispose() {
    widget.animation.removeStatusListener(_onStatus);
    widget.animation.removeListener(_onValue);
    _curved.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.disableAnimations) {
      return _placeholder ? widget.placeholder : widget.child;
    }
    if (_placeholder) return widget.placeholder;
    // 折叠静止态不加任何包裹，保持与未使用本组件时逐帧一致。
    if (_curved.value <= 0) return widget.child;
    return ScaleTransition(
      scale: Tween<double>(begin: 1, end: 0.95).animate(_curved),
      child: FadeTransition(
        opacity: Tween<double>(begin: 1, end: 0).animate(_curved),
        child: widget.child,
      ),
    );
  }
}
