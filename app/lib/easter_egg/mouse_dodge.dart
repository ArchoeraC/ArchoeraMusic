// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 彩蛋 #6：让「所有组件」（装了本包装的按钮 / 条目 / 输入框等）躲避鼠标。
///
/// 行为：开启后指针扫过组件时，组件朝远离指针的方向**平滑移动**（带缓动，
/// 不还原、不考虑布局杂乱）；关闭/未开启时完全无副作用（透传 child）。
///
/// 用 [Listener]（而非 MouseRegion）接收悬停：被包组件自身常已带
/// `MouseRegion`（默认 opaque），会把外层 MouseRegion 挡住；而 Listener 作为
/// 命中路径上的祖先，能稳定拿到 `onPointerHover`。
///
/// 位移用 [TweenAnimationBuilder] 缓动到目标偏移（避免「瞬移」的硬躲避）。
///
/// 监听 [easterEggDodge]（裸 ValueNotifier），不依赖 `ProviderScope`，
/// 因此可安全包在 SButton / SettingTile / SInput 这类通用组件外层。
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'easter_egg_visual_state.dart';

/// 每次躲避的步长与动画时长。
const Duration _kDodgeAnim = Duration(milliseconds: 240);

/// 给任意组件套上「躲避鼠标」能力。
class MouseDodge extends StatefulWidget {
  const MouseDodge({required this.child, super.key});

  final Widget child;

  @override
  State<MouseDodge> createState() => _MouseDodgeState();
}

class _MouseDodgeState extends State<MouseDodge> {
  final math.Random _rng = math.Random();
  Offset _target = Offset.zero;
  DateTime _lastJump = DateTime.fromMillisecondsSinceEpoch(0);

  void _jump(Offset local) {
    // 节流：至少间隔 ~90ms，避免每帧乱跳（配合缓动即为连续平移）。
    final now = DateTime.now();
    if (now.difference(_lastJump).inMilliseconds < 90) return;
    _lastJump = now;

    final size = context.size ?? Size.zero;
    final center = Offset(size.width / 2, size.height / 2);
    // 朝远离指针的方向躲 + 一点随机抖动；累积偏移（不还原）。
    final dirX = local.dx < center.dx ? 1.0 : -1.0;
    final dirY = local.dy < center.dy ? 1.0 : -1.0;
    final dx = dirX * 90 + (_rng.nextDouble() * 2 - 1) * 30;
    final dy = dirY * 70 + (_rng.nextDouble() * 2 - 1) * 30;
    setState(() {
      _target = Offset(
        (_target.dx + dx).clamp(-800.0, 800.0),
        (_target.dy + dy).clamp(-800.0, 800.0),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: easterEggDodge,
      builder: (BuildContext context, bool active, Widget? _) {
        Widget content = widget.child;
        if (active) {
          content = Listener(
            behavior: HitTestBehavior.opaque,
            onPointerHover: (e) => _jump(e.localPosition),
            child: content,
          );
        }
        // 缓动到目标偏移：位移不再是「瞬移」，而是平滑滑过去（且不回位）。
        return TweenAnimationBuilder<Offset>(
          tween: Tween<Offset>(begin: Offset.zero, end: _target),
          duration: _kDodgeAnim,
          curve: Curves.easeOutCubic,
          builder: (BuildContext context, Offset offset, Widget? inner) =>
              Transform.translate(offset: offset, child: inner),
          child: content,
        );
      },
    );
  }
}
