// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 列表滚轮缓动（[SmoothWheelScrollController]）回归：
/// - 滚轮事件不再瞬移，位置在多帧内渐进到目标；
/// - 性能模式（`MediaQuery.disableAnimations`）仍保持原生瞬时滚动；
/// - 触摸拖拽/惯性不受影响（走 `drag()`，不经过 `pointerScroll`）。
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
  testWidgets('滚轮滚动带缓动：多帧渐进，最终到达目标', (tester) async {
    final ctrl = SmoothWheelScrollController();
    addTearDown(ctrl.dispose);
    await tester.pumpWidget(_list(ctrl));
    await tester.pumpAndSettle();

    ctrl.position.pointerScroll(300);
    await tester.pump(); // 启动驱动式动画
    await tester.pump(const Duration(milliseconds: 24));
    final early = ctrl.position.pixels;
    await tester.pump(const Duration(milliseconds: 40));
    final mid = ctrl.position.pixels;
    await tester.pump(const Duration(milliseconds: 400));
    final end = ctrl.position.pixels;

    expect(early, greaterThan(0));
    expect(early, lessThan(300), reason: '首帧不应已经瞬移到目标');
    expect(mid, greaterThan(early), reason: '动画应逐帧推进');
    expect(end, closeTo(300, 0.5));
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

  testWidgets('触摸拖拽不受影响（不经过 pointerScroll）', (tester) async {
    final ctrl = SmoothWheelScrollController();
    addTearDown(ctrl.dispose);
    await tester.pumpWidget(_list(ctrl));
    await tester.pumpAndSettle();

    // 鼠标滚轮先把位置滚到目标，再用手势拖拽：拖拽应立即接管并继续改变位置。
    ctrl.position.pointerScroll(100);
    await tester.pump(const Duration(milliseconds: 20));

    final gesture = await tester.startGesture(const Offset(200, 300));
    await gesture.moveBy(const Offset(0, -140));
    await tester.pump();
    final dragged = ctrl.position.pixels;
    await gesture.up();
    await tester.pumpAndSettle();

    expect(dragged, greaterThan(0), reason: '拖拽期间位置应跟随手指');
  });

  testWidgets('滚轮事件可被触控板惯性取消（delta==0）收尾', (tester) async {
    final ctrl = SmoothWheelScrollController();
    addTearDown(ctrl.dispose);
    await tester.pumpWidget(_list(ctrl));
    await tester.pumpAndSettle();

    ctrl.position.pointerScroll(200);
    await tester.pump(const Duration(milliseconds: 30));
    ctrl.position.pointerScroll(0); // PointerScrollInertiaCancelEvent 的等价调用
    await tester.pumpAndSettle();

    // 不抛异常即可；位置停在取消点附近（不要求精确）。
    expect(ctrl.position.pixels, greaterThanOrEqualTo(0));
    expect(ctrl.position.pixels, lessThanOrEqualTo(200));
  });
}
