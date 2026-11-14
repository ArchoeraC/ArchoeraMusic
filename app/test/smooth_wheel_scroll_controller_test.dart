// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 列表滚轮弹簧（[SmoothWheelScrollController]）回归：
/// - 单个滚轮事件不是瞬移，多帧渐进并精确到达目标；
/// - **快速连滚**：目标累加、速度连续，不掉队（旧 animateTo 实现在这里失败）；
/// - **位置重建**（主题变化等祖先依赖变化会重建 `ScrollPosition`）后连滚
///   目标不归零，不得把列表拉回顶部；
/// - 性能模式（`MediaQuery.disableAnimations`）保持原生瞬时滚动；
/// - 触摸拖拽不受影响（走 `drag()`，且会打断弹簧）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:archoera_music/widgets/common/smooth_wheel_scroll_controller.dart';

/// 被测列表：树形**恒定**（`Builder > Theme > MediaQuery > ListView`），
/// 只改继承数据——与真实主题动画（封面主色变化）同一路径：
/// `Theme` 变化会让 `Scrollable.didChangeDependencies` 无条件重建
/// `ScrollPosition`（每帧一次，但树不重建、像素经 `absorb` 保留）。
Widget _list(
  ScrollController controller, {
  double textScale = 1.0,
  Color seed = Colors.blue,
}) => MaterialApp(
  home: Builder(
    builder: (context) => Theme(
      data: Theme.of(context)
          .copyWith(colorScheme: ColorScheme.fromSeed(seedColor: seed)),
      child: MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: ListView.builder(
          controller: controller,
          itemCount: 400,
          itemBuilder: (_, i) => SizedBox(height: 40, child: Text('row $i')),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('单次滚轮：多帧渐进，最终精确到达目标', (tester) async {
    final ctrl = SmoothWheelScrollController();
    addTearDown(ctrl.dispose);
    await tester.pumpWidget(_list(ctrl));
    await tester.pumpAndSettle();

    ctrl.position.pointerScroll(300);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 24));
    final early = ctrl.position.pixels;
    await tester.pump(const Duration(milliseconds: 40));
    final mid = ctrl.position.pixels;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final end = ctrl.position.pixels;

    expect(early, greaterThan(0));
    expect(early, lessThan(300), reason: '首帧不应已经瞬移到目标');
    expect(mid, greaterThan(early), reason: '弹簧应逐帧推进');
    expect(end, closeTo(300, 0.5));
  });

  testWidgets('快速连滚：位移累加、速度连续，不掉队', (tester) async {
    final ctrl = SmoothWheelScrollController();
    addTearDown(ctrl.dispose);
    await tester.pumpWidget(_list(ctrl));
    await tester.pumpAndSettle();

    // 模拟快速连滚：6 个事件、每 16ms 一档 100px。
    for (var i = 0; i < 6; i++) {
      ctrl.position.pointerScroll(100);
      await tester.pump(const Duration(milliseconds: 16));
    }
    final duringBurst = ctrl.position.pixels;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final end = ctrl.position.pixels;

    expect(
      duringBurst,
      greaterThan(200),
      reason: '连滚期间应已走出大部分位移（animateTo 方案这里只是几十像素）',
    );
    expect(end, closeTo(600, 1), reason: '6 档 × 100px 应全部落地，不丢位移');
  });

  testWidgets('位置被依赖变化重建后，连滚目标不得归零（跳回顶部回归）', (tester) async {
    final ctrl = SmoothWheelScrollController();
    addTearDown(ctrl.dispose);
    await tester.pumpWidget(_list(ctrl));
    await tester.pumpAndSettle();

    // 一档滚轮：弹簧开始运动（目标 300），此刻仍在途中。
    ctrl.position.pointerScroll(300);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    final posBefore = ctrl.position;
    expect(ctrl.position.pixels, greaterThan(0));
    expect(ctrl.position.pixels, lessThan(300));

    // 祖先依赖变化（等价于播放开始后封面取色完成 → 主题逐帧变化）：
    // `Scrollable.didChangeDependencies` 会重建 ScrollPosition，活动经
    // `absorb` 迁移到新位置。
    await tester.pumpWidget(_list(ctrl, textScale: 1.2, seed: Colors.red));
    await tester.pump();
    expect(
      ctrl.position,
      isNot(same(posBefore)),
      reason: '依赖变化应重建 ScrollPosition（本用例的前提）',
    );
    expect(ctrl.position.pixels, greaterThan(0), reason: '重建后像素不应丢失');

    // 同一轮连滚里再滚一档：目标应从 300 累加到 400。
    // 旧实现把累加目标存在 ScrollPosition 上，重建后归零 → 目标变成 100，
    // 列表被弹簧拉回顶部。
    ctrl.position.pointerScroll(100);
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(
      ctrl.position.pixels,
      closeTo(400, 1),
      reason: '连滚目标必须随活动迁移，不能因位置重建而归零',
    );
  });

  testWidgets('性能模式（disableAnimations）保持瞬时滚动', (tester) async {
    final ctrl = SmoothWheelScrollController();
    addTearDown(ctrl.dispose);
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: _list(ctrl),
      ),
    );
    await tester.pumpAndSettle();

    ctrl.position.pointerScroll(300);
    await tester.pump();
    expect(ctrl.position.pixels, closeTo(300, 0.5));
  });

  testWidgets('触摸拖拽不受影响，并会打断弹簧', (tester) async {
    final ctrl = SmoothWheelScrollController();
    addTearDown(ctrl.dispose);
    await tester.pumpWidget(_list(ctrl));
    await tester.pumpAndSettle();

    ctrl.position.pointerScroll(100);
    await tester.pump(const Duration(milliseconds: 16));

    final gesture = await tester.startGesture(const Offset(200, 300));
    await gesture.moveBy(const Offset(0, -140));
    await tester.pump();
    final dragged = ctrl.position.pixels;
    await gesture.up();
    await tester.pumpAndSettle();

    expect(dragged, greaterThan(0), reason: '拖拽期间位置应跟随手指');
    // 松手后不应继续被弹簧拖走（弹簧已被拖拽打断）。
    final afterRelease = ctrl.position.pixels;
    await tester.pump(const Duration(milliseconds: 300));
    expect(ctrl.position.pixels, closeTo(afterRelease, 60));
  });

  testWidgets('触控板惯性取消（delta==0）收尾不抛异常', (tester) async {
    final ctrl = SmoothWheelScrollController();
    addTearDown(ctrl.dispose);
    await tester.pumpWidget(_list(ctrl));
    await tester.pumpAndSettle();

    ctrl.position.pointerScroll(200);
    await tester.pump(const Duration(milliseconds: 30));
    ctrl.position.pointerScroll(0);
    await tester.pumpAndSettle();

    expect(ctrl.position.pixels, greaterThanOrEqualTo(0));
    expect(ctrl.position.pixels, lessThanOrEqualTo(200));
  });
}
