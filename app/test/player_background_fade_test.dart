// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 播放页背景样式切换：新旧背景交叉淡化，而不是硬切。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:archoera_music/stores/app_prefs.dart';
import 'package:archoera_music/widgets/common/cross_fade_switcher.dart';
import 'package:archoera_music/widgets/player/background/player_background.dart';

class _StubPrefs extends AppPrefsNotifier {
  _StubPrefs(this.value);

  AppPrefs value;

  @override
  AppPrefs build() => value;

  /// 不落盘，仅替换内存快照。
  void set(AppPrefs next) => state = next;
}

void main() {
  testWidgets('切换背景样式时新旧两层同时挂载并交叉淡化', (tester) async {
    final stub = _StubPrefs(AppPrefs(initialData: {playerBgTypeKey: 'solid'}));
    final container = ProviderContainer(
      overrides: [appPrefsProvider.overrideWith(() => stub)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: PlayerBackground())),
      ),
    );

    final fade = find.byType(CrossFadeSwitcher);
    expect(fade, findsOneWidget);
    expect(
      find.descendant(of: fade, matching: find.byType(Opacity)),
      findsOneWidget,
    );

    stub.set(AppPrefs(initialData: {playerBgTypeKey: 'gradient'}));
    await tester.pump();

    // 过渡期间：solid 旧层与 gradient 新层同时存在。
    expect(
      find.descendant(of: fade, matching: find.byType(Opacity)),
      findsNWidgets(2),
    );
    expect(
      find.descendant(of: fade, matching: find.byType(ColoredBox)),
      findsWidgets,
    );
    expect(
      find.descendant(of: fade, matching: find.byType(DecoratedBox)),
      findsWidgets,
    );

    await tester.pump(const Duration(milliseconds: 250));
    expect(
      find.descendant(of: fade, matching: find.byType(Opacity)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: fade, matching: find.byType(ColoredBox)),
      findsNothing,
    );
    expect(
      find.descendant(of: fade, matching: find.byType(DecoratedBox)),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
