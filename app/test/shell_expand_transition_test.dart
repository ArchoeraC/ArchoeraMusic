// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// [ShellExpandTransition] 独立测试：折叠态直渲染 child；展开动画途中 child
/// 仍在，动画结束切 placeholder 并真正卸载 child；收起立即切回 child；
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
        placeholder: const Text('placeholder'),
        child: const Text('child'),
      ),
    ),
  );
}

/// 与 [_host] 类似，但 child 换成带 [PageStorageKey] 的可滚动列表，用于验证
/// 卸载/重挂载后滚动位置的保留。每次重挂载由调用方传入全新的
/// [ScrollController]，从而排除 controller 自身记忆 offset 的可能，确保恢复
/// 只能来自 [ShellExpandTransition] 持有的 [PageStorageBucket]。
Widget _scrollHost(Animation<double> animation, ScrollController controller) {
  return MaterialApp(
    home: Scaffold(
      body: ShellExpandTransition(
        animation: animation,
        placeholder: const Text('placeholder'),
        child: ListView.builder(
          key: const PageStorageKey<String>('test.list'),
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
    testWidgets('折叠态显示 child、隐藏 placeholder', (tester) async {
      await tester.pumpWidget(_host(const AlwaysStoppedAnimation<double>(0)));
      expect(find.text('child'), findsOneWidget);
      expect(find.text('placeholder'), findsNothing);
    });

    testWidgets('展开：动画途中 child 仍在，结束后切 placeholder 并卸载', (tester) async {
      final c = _controller(tester);
      await tester.pumpWidget(_host(c));
      expect(find.text('child'), findsOneWidget);

      c.forward();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      // 动画途中：child 仍在（只是被缩放/淡出）。
      expect(find.text('child'), findsOneWidget);
      expect(find.text('placeholder'), findsNothing);

      await tester.pumpAndSettle();
      expect(find.text('child'), findsNothing);
      expect(find.text('placeholder'), findsOneWidget);
    });

    testWidgets('收起：立即切回 child 并反向动画', (tester) async {
      final c = _controller(tester);
      await tester.pumpWidget(_host(c));
      c.value = 1;
      await tester.pumpAndSettle();
      expect(find.text('placeholder'), findsOneWidget);

      c.reverse();
      await tester.pump();
      expect(find.text('child'), findsOneWidget);
      expect(find.text('placeholder'), findsNothing);
      await tester.pumpAndSettle();
      expect(find.text('child'), findsOneWidget);
    });

    testWidgets('disableAnimations：展开/折叠均直切', (tester) async {
      final c = _controller(tester);
      await tester.pumpWidget(_host(c, disableAnimations: true));
      expect(find.text('child'), findsOneWidget);

      c.value = 1;
      await tester.pump();
      expect(find.text('placeholder'), findsOneWidget);
      expect(find.text('child'), findsNothing);

      c.value = 0;
      await tester.pump();
      expect(find.text('child'), findsOneWidget);
    });

    testWidgets('卸载/重挂载后 PageStorage 恢复滚动位置', (tester) async {
      final c = _controller(tester);
      await tester.pumpWidget(_scrollHost(c, ScrollController()));
      await tester.pump();
      final scrollable = find.byType(Scrollable);
      await tester.drag(scrollable, const Offset(0, -1200));
      await tester.pumpAndSettle();
      final before = tester.widget<Scrollable>(scrollable).controller!.offset;
      expect(before, greaterThan(1000));

      // 展开 → 卸载 child；收起 → 用全新 controller 重挂载。
      c.value = 1;
      await tester.pumpAndSettle();
      expect(find.text('placeholder'), findsOneWidget);

      c.reverse();
      await tester.pump();
      await tester.pumpWidget(_scrollHost(c, ScrollController()));
      await tester.pumpAndSettle();
      final after = tester
          .widget<Scrollable>(find.byType(Scrollable))
          .controller!
          .offset;
      expect(after, closeTo(before, 1));
    });
  });
}
