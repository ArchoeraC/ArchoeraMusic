// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 无边框窗口按钮回归：
/// - ghost 按钮无底色时必须保持透明（`Colors.transparent.withValues(alpha: 1)`
///   曾变成不透明黑，窗口按钮出现黑色圆底）；
/// - 自动隐藏：默认隐藏 + 不接收点击，指针进入显示、离开隐藏。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:archoera_music/widgets/layout/window_controls.dart';
import 'package:archoera_music/widgets/player/s_controls.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('ghost 圆形按钮保持透明底色', (tester) async {
    await tester.pumpWidget(
      _host(
        Center(
          child: SButton(
            label: 'close',
            icon: Icons.close,
            variant: SButtonVariant.ghost,
            circle: true,
            onPressed: () {},
          ),
        ),
      ),
    );

    final container = tester.widget<AnimatedContainer>(
      find.descendant(
        of: find.byType(SButton),
        matching: find.byType(AnimatedContainer),
      ),
    );
    final decoration = container.decoration! as BoxDecoration;
    expect(decoration.color?.a, 0, reason: '幽灵按钮不应带任何不透明底色');
  });

  testWidgets('自动隐藏：隐藏态不接收点击，悬停显示、移出恢复隐藏', (tester) async {
    await tester.pumpWidget(
      _host(
        Center(
          child: AutoHideOnHover(
            enabled: true,
            child: const SizedBox(
              width: 120,
              height: 40,
              child: Text('controls'),
            ),
          ),
        ),
      ),
    );

    double opacity() => tester
        .widget<AnimatedOpacity>(
          find.descendant(
            of: find.byType(AutoHideOnHover),
            matching: find.byType(AnimatedOpacity),
          ),
        )
        .opacity;
    bool ignoring() => tester
        .widget<IgnorePointer>(
          find.descendant(
            of: find.byType(AutoHideOnHover),
            matching: find.byType(IgnorePointer),
          ),
        )
        .ignoring;

    // 初始：透明 + 不接收指针。
    expect(opacity(), 0);
    expect(ignoring(), isTrue);

    // 指针进入右上角区域 → 显示并可点击。
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.text('controls')));
    await tester.pumpAndSettle();
    expect(opacity(), 1);
    expect(ignoring(), isFalse);

    // 指针移出 → 恢复隐藏。
    await gesture.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    expect(opacity(), 0);
    expect(ignoring(), isTrue);
  });

  testWidgets('未开启自动隐藏时原样渲染', (tester) async {
    await tester.pumpWidget(
      _host(
        Center(
          child: AutoHideOnHover(
            enabled: false,
            child: const Text('always'),
          ),
        ),
      ),
    );

    expect(find.text('always'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AutoHideOnHover),
        matching: find.byType(AnimatedOpacity),
      ),
      findsNothing,
    );
  });
}
