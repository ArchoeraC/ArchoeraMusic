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

Widget _host({required bool expanded, bool disableAnimations = false}) {
  return MaterialApp(
    home: Scaffold(
      body: ShellExpandTransition(
        expanded: expanded,
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
Widget _scrollHost({
  required bool expanded,
  required ScrollController controller,
}) {
  return MaterialApp(
    home: Scaffold(
      body: ShellExpandTransition(
        expanded: expanded,
        duration: const Duration(milliseconds: 100),
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

void main() {
  group('ShellExpandTransition', () {
    testWidgets('折叠态显示 child、隐藏 placeholder', (tester) async {
      await tester.pumpWidget(_host(expanded: false));
      expect(find.text('child'), findsOneWidget);
      expect(find.text('placeholder'), findsNothing);
    });

    testWidgets('展开：动画途中 child 仍在，结束后切 placeholder 并卸载 child', (tester) async {
      await tester.pumpWidget(_host(expanded: false));
      await tester.pumpWidget(_host(expanded: true));

      // 动画进行中：child 仍留在树上。
      await tester.pump();
      expect(find.text('child'), findsOneWidget);
      expect(find.text('placeholder'), findsNothing);

      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('child'), findsOneWidget);
      expect(find.text('placeholder'), findsNothing);

      // 动画结束：child 真正从树上移除，placeholder 出现。
      await tester.pumpAndSettle();
      expect(find.text('child'), findsNothing);
      expect(find.text('placeholder'), findsOneWidget);
    });

    testWidgets('收起：立即切回 child 并反向动画', (tester) async {
      await tester.pumpWidget(_host(expanded: true));
      expect(find.text('placeholder'), findsOneWidget);
      expect(find.text('child'), findsNothing);

      await tester.pumpWidget(_host(expanded: false));
      // 收起当帧即恢复 child（进入动画有内容）。
      expect(find.text('child'), findsOneWidget);
      expect(find.text('placeholder'), findsNothing);

      await tester.pumpAndSettle();
      expect(find.text('child'), findsOneWidget);
      expect(find.text('placeholder'), findsNothing);
    });

    testWidgets('卸载/重挂载后 PageStorage 恢复滚动位置', (tester) async {
      final first = ScrollController();
      await tester.pumpWidget(_scrollHost(expanded: false, controller: first));
      first.jumpTo(1200);
      await tester.pump();
      expect(first.offset, 1200);

      // 展开：动画结束切 placeholder，child 与列表真正卸载。
      await tester.pumpWidget(_scrollHost(expanded: true, controller: first));
      await tester.pumpAndSettle();
      expect(find.text('placeholder'), findsOneWidget);
      expect(find.byType(ListView), findsNothing);

      // 重挂载时用全新 controller：offset 只能来自 PageStorage 恢复。
      final second = ScrollController();
      await tester.pumpWidget(_scrollHost(expanded: false, controller: second));
      await tester.pump();
      expect(second.offset, 1200);

      first.dispose();
      second.dispose();
    });

    testWidgets('disableAnimations：展开/折叠均直切', (tester) async {
      await tester.pumpWidget(_host(expanded: false, disableAnimations: true));
      expect(find.text('child'), findsOneWidget);
      expect(find.text('placeholder'), findsNothing);

      await tester.pumpWidget(_host(expanded: true, disableAnimations: true));
      expect(find.text('placeholder'), findsOneWidget);
      expect(find.text('child'), findsNothing);

      await tester.pumpWidget(_host(expanded: false, disableAnimations: true));
      expect(find.text('child'), findsOneWidget);
      expect(find.text('placeholder'), findsNothing);
    });
  });
}
