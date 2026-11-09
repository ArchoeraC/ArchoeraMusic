// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// [ShellExpandTransition] 独立测试：折叠态直渲染 child；展开动画途中
/// child 仍在；动画结束只 [Offstage] 停绘/停布局，**不再卸载**；收起立即恢复；
/// 性能模式直切。不依赖 go_router / Riverpod。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:archoera_music/app/shell_expand_transition.dart';

Widget _host(Animation<double> animation, {bool disableAnimations = false}) {
  return MaterialApp(
    home: Scaffold(
      body: ShellExpandTransition(
        animation: animation,
        disableAnimations: disableAnimations,
        child: const Text('child'),
      ),
    ),
  );
}

/// 带滚动列表的宿主：验证展开/收起后滚动位置由 State 保留（不重建）。
Widget _scrollHost(Animation<double> animation, ScrollController controller) {
  return MaterialApp(
    home: Scaffold(
      body: ShellExpandTransition(
        animation: animation,
        child: ListView.builder(
          controller: controller,
          itemCount: 200,
          itemBuilder: (_, i) => SizedBox(height: 50, child: Text('item$i')),
        ),
      ),
    ),
  );
}

AnimationController _controller(WidgetTester tester) {
  final c = AnimationController(
    vsync: const TestVSync(),
    duration: const Duration(milliseconds: 100),
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  group('ShellExpandTransition', () {
    testWidgets('折叠态显示 child', (tester) async {
      await tester.pumpWidget(_host(const AlwaysStoppedAnimation<double>(0)));
      expect(find.text('child'), findsOneWidget);
    });

    testWidgets('展开：动画途中 child 仍在，结束后只停绘不卸载', (tester) async {
      final c = _controller(tester);
      await tester.pumpWidget(_host(c));
      expect(find.text('child'), findsOneWidget);

      c.forward();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      // 动画途中：child 仍在（只是被缩放/淡出）。
      expect(find.text('child'), findsOneWidget);

      await tester.pumpAndSettle();
      // 完全展开：默认 finder 跳过 offstage，但 element/state 仍保留。
      expect(find.text('child'), findsNothing);
      expect(find.text('child', skipOffstage: false), findsOneWidget);
    });

    testWidgets('收起：从停绘态恢复 child', (tester) async {
      final c = _controller(tester);
      await tester.pumpWidget(_host(c));
      c.value = 1;
      await tester.pumpAndSettle();
      expect(find.text('child'), findsNothing);

      c.reverse();
      await tester.pump();
      expect(find.text('child'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('child'), findsOneWidget);
    });

    testWidgets('disableAnimations：展开/折叠均直切', (tester) async {
      final c = _controller(tester);
      await tester.pumpWidget(_host(c, disableAnimations: true));
      expect(find.text('child'), findsOneWidget);

      c.value = 1;
      await tester.pump();
      expect(find.text('child'), findsNothing);
      expect(find.text('child', skipOffstage: false), findsOneWidget);

      c.value = 0;
      await tester.pump();
      expect(find.text('child'), findsOneWidget);
    });

    testWidgets('展开/收起后滚动位置保留（State 不重建）', (tester) async {
      final c = _controller(tester);
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_scrollHost(c, controller));
      await tester.pump();
      final scrollable = find.byType(Scrollable);
      await tester.drag(scrollable, const Offset(0, -1200));
      await tester.pumpAndSettle();
      final before = controller.offset;
      expect(before, greaterThan(1000));

      c.value = 1;
      await tester.pumpAndSettle();
      expect(find.text('item0'), findsNothing);

      c.reverse();
      await tester.pumpAndSettle();
      expect(controller.offset, closeTo(before, 1));
    });
  });
}
