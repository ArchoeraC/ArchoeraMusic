// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 设置页效果预览回归：预览小样在常规 / 窄窗口下都能渲染、不溢出，
/// 且测试环境不启动循环动画（保证 pumpAndSettle 可收敛）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:archoera_music/l10n/generated/app_localizations.dart';
import 'package:archoera_music/settings/settings_previews.dart';
import 'package:archoera_music/settings/settings_widgets.dart';
import 'package:archoera_music/stores/app_prefs.dart';
import 'package:archoera_music/eta/icon/eta_icons.dart';

class _NoSavePrefs extends AppPrefsNotifier {
  @override
  AppPrefs build() => AppPrefs();
}

Widget _host(Widget child) {
  return ProviderScope(
    overrides: [appPrefsProvider.overrideWith(_NoSavePrefs.new)],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: SizedBox(width: 420, child: child),
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('全部预览小样可渲染且不抛异常', (tester) async {
    final prefs = AppPrefs();
    await tester.pumpWidget(
      _host(
        Column(
          children: [
            BackgroundEffectPreview(prefs: prefs),
            const SizedBox(height: 12),
            ThemeCoverPreview(prefs: prefs),
            const SizedBox(height: 12),
            LyricsStylePreview(prefs: prefs),
            const SizedBox(height: 12),
            ListDisplayPreview(prefs: prefs),
            const SizedBox(height: 12),
            SpectrumStylePreview(prefs: prefs),
            const SizedBox(height: 12),
            const CoverTransitionPreview(style: 'scale'),
            const SizedBox(height: 12),
            const RouteTransitionPreview(style: 'fade'),
            const SizedBox(height: 12),
            RippleEffectPreview(prefs: prefs),
            const SizedBox(height: 12),
            const LyricsEdgeFadePreview(mode: 'wall'),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄窗口下预览不溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final prefs = AppPrefs();
    await tester.pumpWidget(
      _host(
        Column(
          children: [
            BackgroundEffectPreview(prefs: prefs),
            const SizedBox(height: 12),
            ThemeCoverPreview(prefs: prefs, compact: true),
            const SizedBox(height: 12),
            LyricsEdgeFadePreview(mode: prefs.lyricsEdgeFade),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('设置分区预览默认收起，点击眼睛后展开', (tester) async {
    await tester.pumpWidget(
      _host(
        const SettingSection(
          title: 'Section',
          preview: Text('PREVIEW'),
          children: [Text('CHILD')],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('CHILD'), findsOneWidget);
    expect(find.text('PREVIEW'), findsNothing, reason: '预览默认不占据页面高度');

    await tester.tap(find.byIcon(EtaIcons.eyeOutline));
    await tester.pumpAndSettle();
    expect(find.text('PREVIEW'), findsOneWidget);

    await tester.tap(find.byIcon(EtaIcons.eyeCloseOutline));
    await tester.pumpAndSettle();
    expect(find.text('PREVIEW'), findsNothing);
  });
}
