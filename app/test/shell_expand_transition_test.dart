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
