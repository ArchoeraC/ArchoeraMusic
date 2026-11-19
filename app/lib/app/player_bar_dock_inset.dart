// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/widgets.dart';

import '../widgets/layout/player_bar.dart';
import 'player_bar_exit_transition.dart';

/// 停靠播放条给内容层留出的底部让位。
///
/// 让位高度由两个**独立**的可见性因子相乘得到，缺一不可：
///  1. **播放条自身显隐**（`visible` = 有源或恢复了队列）：与播放条内部
///     `AnimatedSwitcher` 的滑入/滑出同步，展开过程里让位与条一起长/一起收
///     ——历史实现是按布尔值瞬间写死 [kDockedPlayerBarHeight]，于是「拉起
///     播放条」会先空出一整条空白再等条滑进来；清空队列时又会让内容先掉
///     下去。
///  2. **播放页让出相位**（`routeAnimation`）：播放页展开时先让播放条滑出
///     （见 [playerBarExitProgress]），这段里让位必须同步收掉，否则条走了
///     还留着一块占位；收起时页面落到底、播放条回位，让位再跟着长回来。
///
/// 两者相乘后作为 [Padding]，是**布局级**动画（会逐帧重排内容层）：让位本身
/// 就是布局量，无法用 paint 级变换表达。只在播放条显隐（300ms）与播放页
/// 进出（120ms）期间发生，且播放页完全展开后内容层已 `Offstage` 停布局。
class PlayerBarDockInset extends StatefulWidget {
  const PlayerBarDockInset({
    super.key,
    required this.visible,
    required this.child,
    this.routeAnimation,
    this.height = kDockedPlayerBarHeight,
    this.duration = const Duration(milliseconds: 300),
  });

  /// 播放条本身是否应该显示（与 `PlayerBar` 内的显隐条件保持一致）。
  final bool visible;

  /// 播放页路由动画；null 表示没有播放页（让位不受影响）。
  final Animation<double>? routeAnimation;

  /// 让位高度（停靠条完整露出时）。
  final double height;

  /// 播放条显隐的过渡时长（与 `AnimatedSwitcher` 一致；性能模式传 0 直切）。
  final Duration duration;

  final Widget child;

  @override
  State<PlayerBarDockInset> createState() => _PlayerBarDockInsetState();
}

class _PlayerBarDockInsetState extends State<PlayerBarDockInset>
    with SingleTickerProviderStateMixin {
  late final AnimationController _presence = AnimationController(
    vsync: this,
    duration: widget.duration,
    value: widget.visible ? 1 : 0,
  );

  @override
  void didUpdateWidget(covariant PlayerBarDockInset oldWidget) {
    super.didUpdateWidget(oldWidget);
    _presence.duration = widget.duration;
    if (widget.visible != oldWidget.visible) {
      if (widget.visible) {
        _presence.forward();
      } else {
        _presence.reverse();
      }
    }
  }

  /// 播放条自身的显隐进度（0 = 完全收起，1 = 完全露出）。
  ///
  /// 曲线与播放条内部 `AnimatedSwitcher` 的 `switchIn/switchOut` 对齐：
  /// 进入 easeOutCubic、退出 easeInCubic，两边的底部边缘才会始终咬合。
  double get _presenceValue {
    final raw = _presence.value;
    return _presence.status == AnimationStatus.reverse
        ? Curves.easeInCubic.transform(raw)
        : Curves.easeOutCubic.transform(raw);
  }

  @override
  void dispose() {
    _presence.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_presence, widget.routeAnimation]),
      builder: (context, child) {
        final route = widget.routeAnimation;
        final exit = route == null ? 0.0 : playerBarExitProgress(route.value);
        final inset = widget.height * _presenceValue * (1 - exit);
        return Padding(
          padding: EdgeInsets.only(bottom: inset),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}
