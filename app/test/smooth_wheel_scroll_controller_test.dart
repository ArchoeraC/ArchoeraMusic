// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 列表滚轮弹簧（[SmoothWheelScrollController]）回归：
/// - 单个滚轮事件不是瞬移，多帧渐进并精确到达目标；
/// - **快速连滚**：目标累加、速度连续，不掉队（旧 animateTo 实现在这里失败）；
/// - 性能模式（`MediaQuery.disableAnimations`）保持原生瞬时滚动；
/// - 触摸拖拽不受影响（走 `drag()`，且会打断弹簧）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:archoera_music/widgets/common/smooth_wheel_scroll_controller.dart';

Widget _list(ScrollController controller) => MaterialApp(
  home: ListView.builder(
    controller: controller,
    itemCount: 400,
    itemBuilder: (_, i) => SizedBox(height: 40, child: Text('row $i')),
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
