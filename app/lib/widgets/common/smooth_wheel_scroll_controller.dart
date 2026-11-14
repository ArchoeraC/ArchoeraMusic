// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:math' as math;

import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:material_ui/material_ui.dart';

import '../../utils/spring.dart';

/// 给列表的**滚轮 / 触控板滚动**补上与歌词页同款的弹簧跟随。
///
/// 只接管 `ScrollPosition.pointerScroll`（鼠标滚轮、触控板滚动信号）：
/// - **触摸拖拽**走 `drag()`、**键盘**走 `ScrollAction`，都不经过这里；
///   任何新滚动活动（拖拽 / 惯性 / 外部 `animateTo`）都会替换掉弹簧活动，
///   不会出现「手在拖、弹簧还在抢位置」；
/// - `MediaQuery.disableAnimations`（性能模式）退回原生瞬时滚动。
///
/// **为什么用弹簧而不是 `animateTo`**：`animateTo` 每来一个滚轮事件都从当前
/// 位置重启一条缓动曲线（初速度归零），且新动画首帧的 elapsed 为 0——快速连滚
/// （事件按帧到达）时几乎推不动，列表明显跟不上轮子。这里：
/// - **一个常驻活动 + 一个 Ticker**：滚轮事件只在活动上**改目标**，不重启动画，
///   也不重置计时；
/// - 目标**累加**（`target += delta`），连滚时目标一直前移，位移不丢；
/// - 弹簧（[Spring1D]）保速重定向，与歌词页 `discreteScroll` 同一套物理；
/// - 临界阻尼（ζ = 1，不回弹），松手后自然缓停。
class SmoothWheelScrollController extends ScrollController {
  SmoothWheelScrollController({
    super.initialScrollOffset,
    super.keepScrollOffset,
    super.debugLabel,
  });

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _SmoothWheelScrollPosition(
    physics: physics,
    context: context,
    initialPixels: initialScrollOffset,
    keepScrollOffset: keepScrollOffset,
    oldPosition: oldPosition,
    debugLabel: debugLabel,
  );
}

class _SmoothWheelScrollPosition extends ScrollPositionWithSingleContext {
  _SmoothWheelScrollPosition({
    required super.physics,
    required super.context,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
  });

  @override
  void pointerScroll(double delta) {
    // 触控板「惯性取消」事件：直接收尾。
    if (delta == 0.0) {
      goIdle();
      return;
    }
    if (!hasPixels || !hasContentDimensions) return;

    final BuildContext? ctx = context.notificationContext;
    // 性能模式（MediaQuery.disableAnimations）：保持原生瞬时滚动。
    if (ctx != null && (MediaQuery.maybeDisableAnimationsOf(ctx) ?? false)) {
      super.pointerScroll(delta);
      return;
    }

    final ScrollActivity? current = activity;
    if (current is _WheelScrollActivity) {
      // 连滚：只改目标，不重启活动 / 不重置 Ticker 计时（这是快速滚动的关键）。
      //
      // 目标**只能**从弹簧自身取，不能缓存在本位置对象上：主题变化等祖先依赖
      // 变化会让 `Scrollable.didChangeDependencies` 重建 `ScrollPosition`
      // （见 flutter 的 `_ScrollableState.didChangeDependencies`，主题动画期间
      // 每帧一次），活动与弹簧经 `absorb` 迁到新位置，而位置上缓存的累加目标
      // 会归零——下一次滚轮就会以 0 为起点重定目标，把列表从当前位置拉回顶部
      // （播放开始时封面取色完成 → 主题变化 → 滚动即跳顶）。
      final double target = _clampTarget(current.target + delta);
      current.retarget(target);
      updateUserScrollDirection(
        delta > 0 ? ScrollDirection.forward : ScrollDirection.reverse,
      );
      return;
    }

    final double target = _clampTarget(pixels + delta);
    if (target == pixels) return;
    updateUserScrollDirection(
      delta > 0 ? ScrollDirection.forward : ScrollDirection.reverse,
    );
    beginActivity(
      _WheelScrollActivity(
        this,
        context.vsync,
        initialPixels: pixels,
        initialTarget: target,
      ),
    );
  }

  double _clampTarget(double value) =>
      math.min(math.max(value, minScrollExtent), maxScrollExtent);
}

/// 弹簧驱动的滚轮活动：一个 Ticker + 一个 [Spring1D]，目标可随时改。
///
/// 用真实的 [ScrollActivity] 而不是自己 `setPixels`：`ScrollPositionWithSingleContext`
/// 的 `setPixels` 断言 `activity!.isScrolling`，并且开始/结束/更新通知、拖拽接管、
/// 指针穿透设置都由框架统一处理。
class _WheelScrollActivity extends ScrollActivity {
  _WheelScrollActivity(
    super.delegate,
    TickerProvider vsync, {
    required double initialPixels,
    required double initialTarget,
  }) : _spring = Spring1D(initialPosition: initialPixels, params: _params) {
    _ticker = vsync.createTicker(_tick);
    _ticker.start();
    _spring.setTarget(initialTarget);
  }

  /// ζ = damping / (2·√(stiffness·mass)) = 90 / (2·√2000) ≈ 1.0，临界阻尼（不回弹）。
  ///
  /// ω = √(stiffness/mass) ≈ 45 rad/s：一档滚轮（~100px）约 60–80ms 走完大半；
  /// 快速连滚时稳态滞后 ≈ 2·v/ω（v = 目标速度），保证「轮子越快、列表跟得越快」
  /// 而不是越落越远。
  static const SpringParams _params = SpringParams(
    mass: 1.0,
    stiffness: 2000.0,
    damping: 90.0,
  );

  final Spring1D _spring;
  late final Ticker _ticker;
  Duration _lastTick = Duration.zero;

  @override
  bool get isScrolling => true;

  @override
  bool get shouldIgnorePointer => false;

  @override
  double get velocity => _spring.velocity;

  /// 当前弹簧目标（像素）。
  ///
  /// 连滚时由 `pointerScroll` 以它为准累加位移。这是弹簧自己的状态，
  /// 随活动经 `absorb` 迁移到新 `ScrollPosition`；不能改用位置对象上的
  /// 字段缓存（位置会被 `Scrollable.didChangeDependencies` 重建）。
  double get target => _spring.targetPosition;

  /// 滚轮事件改目标：保留当前速度（[Spring1D.setTarget] 保速重定向）。
  void retarget(double target) => _spring.setTarget(target);

  void _tick(Duration elapsed) {
    final double dt = (elapsed - _lastTick).inMicroseconds / 1000000.0;
    _lastTick = elapsed;
    if (dt <= 0) return;
    // 页面挂起后首帧 delta 可能很大：钳到 0.1s 推进（丢掉这一帧会让弹簧停摆）。
    delegate.setPixels(_spring.update(dt > 0.1 ? 0.1 : dt));
    if (_spring.arrived()) delegate.goIdle();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }
}

/// 为**无状态**组件里一次性创建的滚动容器注入 [SmoothWheelScrollController]。
///
/// 控制器属于本作用域的 State：父级重建只会重新执行 [builder]（沿用同一个
/// 控制器，滚动位置不丢），并随作用域一起销毁；不必为「只差一个控制器」把
/// 无状态组件整体改成 StatefulWidget。
///
/// ```dart
/// SmoothWheelScrollScope(
///   builder: (context, controller) =>
///       ListView.builder(controller: controller, ...),
/// )
/// ```
class SmoothWheelScrollScope extends StatefulWidget {
  const SmoothWheelScrollScope({super.key, required this.builder});

  /// 用控制器构建滚动容器（传给 `ListView` / `SingleChildScrollView` 等）。
  final Widget Function(BuildContext context, ScrollController controller)
  builder;

  @override
  State<SmoothWheelScrollScope> createState() => _SmoothWheelScrollScopeState();
}

class _SmoothWheelScrollScopeState extends State<SmoothWheelScrollScope> {
  final ScrollController _controller = SmoothWheelScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _controller);
}
