// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 「性能 / 渲染」分类的歌词边缘渐隐选项：三段控件与偏好接线。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:archoera_music/l10n/generated/app_localizations.dart';
import 'package:archoera_music/settings/settings_sections.dart';
import 'package:archoera_music/stores/app_prefs.dart';

/// 不落盘的偏好容器（避免测试写入真实 prefs.json）。
class _NoSavePrefs extends AppPrefsNotifier {
  @override
  AppPrefs build() => AppPrefs();

  @override
  void setLyricsEdgeFade(String value) {
    state = state.copyWithLyricsEdgeFade(value);
  }

  @override
  void setRippleRender({bool? shader, bool? lowRes, bool? damageClip}) {
    state = state.copyWithRippleRender(
      shader: shader,
      lowRes: lowRes,
      damageClip: damageClip,
    );
  }
}

void main() {
  testWidgets('歌词边缘渐隐：默认逐行，可切到遮罩/关闭并写入偏好', (tester) async {
    final container = ProviderContainer(
      overrides: [appPrefsProvider.overrideWith(_NoSavePrefs.new)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(
            body: SingleChildScrollView(child: RenderSection()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(container.read(appPrefsProvider).lyricsEdgeFade, 'wall');
    // 下拉当前值显示「逐行」。
    expect(find.text('Per-line'), findsOneWidget);

    Future<void> pick(String current, String next) async {
      await tester.tap(find.text(current).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text(next).last);
      await tester.pumpAndSettle();
    }

    await pick('Per-line', 'Mask');
    expect(container.read(appPrefsProvider).lyricsEdgeFade, 'shader');

    await pick('Mask', 'Off');
    expect(container.read(appPrefsProvider).lyricsEdgeFade, 'off');

    await pick('Off', 'Per-line');
    expect(container.read(appPrefsProvider).lyricsEdgeFade, 'wall');
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄窗口不溢出（下拉控件比分段控件更省宽）', (tester) async {
    tester.view.physicalSize = const Size(380, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final container = ProviderContainer(
      overrides: [appPrefsProvider.overrideWith(_NoSavePrefs.new)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(
            body: SingleChildScrollView(child: RenderSection()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
