// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 彩蛋 #6 组件躲避（MouseDodge）回归测试。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/easter_egg/easter_egg_visual_state.dart';
import 'package:archoera_music/easter_egg/mouse_dodge.dart';
import 'package:archoera_music/l10n/generated/app_localizations.dart';
import 'package:archoera_music/widgets/player/s_controls.dart';

/// 用鼠标手势在 [finder] 上连续悬停，触发躲避。
Future<void> _hover(WidgetTester tester, Finder finder) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: tester.getCenter(finder));
  await tester.pump();
  for (var i = 0; i < 4; i++) {
    await mouse.moveTo(tester.getCenter(finder) + Offset(2.0 + i, 0));
    await tester.pump(const Duration(milliseconds: 130));
  }
  await mouse.removePointer();
  // 等缓动动画结束，取稳定位置。
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('MouseDodge 包真实 SButton：开启后悬停位移（内层 opaque MouseRegion 场景）', (
    tester,
  ) async {
    easterEggDodge.value = true;
    addTearDown(() => easterEggDodge.value = false);

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh', 'CN'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          ...GlobalMaterialLocalizations.delegates,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Center(child: SButton(label: '测试', onPressed: () {})),
        ),
      ),
    );
    // 注意：量 SButton 内部的文字（RenderTransform 自身的 getTopLeft 不含
    // 自身位移，量其子节点才反映位移）。
    final probe = find.text('测试');
    final before = tester.getTopLeft(probe);

    await _hover(tester, find.byType(SButton));
    expect(tester.getTopLeft(probe), isNot(before), reason: 'SButton 悬停应位移');
  });

  testWidgets('MouseDodge：开启后指针扫过 → 组件位移且不回位', (tester) async {
    const key = Key('probe');
    easterEggDodge.value = true;
    addTearDown(() => easterEggDodge.value = false);

    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: MouseDodge(
            child: Container(
              key: key,
              width: 120,
              height: 40,
              color: const Color(0xFF333333),
            ),
          ),
        ),
      ),
    );
    final before = tester.getTopLeft(find.byKey(key));

    await _hover(tester, find.byKey(key));
    expect(
      tester.getTopLeft(find.byKey(key)),
      isNot(before),
      reason: '鼠标扫过后组件应位移',
    );
    // 不回位：再 pump 若干帧位置不变。
    final moved = tester.getTopLeft(find.byKey(key));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.getTopLeft(find.byKey(key)), moved);
  });

  testWidgets('MouseDodge：未开启时不动', (tester) async {
    const key = Key('probe2');
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: MouseDodge(
            child: Container(
              key: key,
              width: 120,
              height: 40,
              color: const Color(0xFF333333),
            ),
          ),
        ),
      ),
    );
    final before = tester.getTopLeft(find.byKey(key));

    await _hover(tester, find.byKey(key));
    expect(tester.getTopLeft(find.byKey(key)), before);
  });
}
