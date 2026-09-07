// ArchoeraMusic UI
// SPDX-License-Identifier: AGPL-3.0-or-later

// 回归：隔离区列表首次无记录时（quarantine 目录不存在）应正常显示「空」，
// 不因 const 列表 sort 异常卡在加载态（Cannot modify an unmodifiable list）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/l10n/generated/app_localizations.dart';
import 'package:archoera_music/settings/scans_section.dart';
import 'package:archoera_music/stores/app_prefs.dart';

class _NoSideEffectPrefs extends AppPrefsNotifier {
  @override
  AppPrefs build() => AppPrefs();
}

void main() {
  testWidgets('隔离区：无隔离目录时渲染「空」且不卡加载', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appPrefsProvider.overrideWith(_NoSideEffectPrefs.new)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(
            body: SingleChildScrollView(child: ScansSection()),
          ),
        ),
      ),
    );
    // 等 initState 的 _refreshQuarantine 异步收敛
    await tester.pumpAndSettle();

    // 无隔离目录时应结束加载态，不残留无限转圈
    expect(find.byType(LinearProgressIndicator), findsNothing,
        reason: '无隔离目录时应结束加载态，不残留 loading');
    // 空状态文案（测试默认 en locale）
    expect(find.text('No quarantined files'), findsOneWidget,
        reason: '应展示隔离区空状态而非一直加载');
  });
}
