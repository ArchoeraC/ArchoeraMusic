// ArchoeraMusic UI
// SPDX-License-Identifier: AGPL-3.0-or-later

// 设置 → 刮削 布局回归：空闲态应同时展示「开始刮削」与「开始整理」入口，
// 且「仅整理」配置（目标/模板）不被进度区覆盖。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/l10n/generated/app_localizations.dart';
import 'package:archoera_music/settings/settings_sections.dart';
import 'package:archoera_music/stores/app_prefs.dart';

class _NoSideEffectPrefs extends AppPrefsNotifier {
  @override
  AppPrefs build() => AppPrefs();
}

void main() {
  testWidgets('刮削页空闲态：开始刮削 + 开始整理双入口、配置区可用', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appPrefsProvider.overrideWith(_NoSideEffectPrefs.new)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(
            body: SingleChildScrollView(child: ScrapeSection()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Start Scraping'), findsOneWidget);
    expect(find.text('Start Organizing'), findsOneWidget);
    // 「仅整理」配置区标题仍在（不被状态覆盖）
    expect(find.text('Organize Only'), findsOneWidget);
  });
}
