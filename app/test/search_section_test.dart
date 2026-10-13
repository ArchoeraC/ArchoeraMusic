// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// 回归：.lrc 子开关**仅在总开关开启时可用**（默认关闭时禁用）；总开关默认关。
// 关闭态下 SearchSection 不得触碰 / 构造 SearchService（零成本）。
// 开启态下切换 .lrc 子开关应写偏好并触发**增量重建**（P4，经测试接缝观测，
// 不触碰真实 FFI / search.db）。

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/l10n/generated/app_localizations.dart';
import 'package:archoera_music/services/search/search_service.dart';
import 'package:archoera_music/settings/search_section.dart';
import 'package:archoera_music/stores/app_prefs.dart';

class _Prefs extends AppPrefsNotifier {
  _Prefs(this._initial);
  final AppPrefs _initial;

  /// 记录 setSearchIndex 调用（不影响全局 appPrefsSnapshot / 不落盘）。
  bool? lastIndexLrc;
  int setSearchIndexCalls = 0;

  @override
  AppPrefs build() => _initial;

  @override
  void setSearchIndex({bool? enabled, bool? indexLrc}) {
    setSearchIndexCalls++;
    lastIndexLrc = indexLrc ?? lastIndexLrc;
    state = state.copyWithSearchIndex(enabled: enabled, indexLrc: indexLrc);
  }
}

Widget _wrap(AppPrefs prefs) => ProviderScope(
  overrides: [appPrefsProvider.overrideWith(() => _Prefs(prefs))],
  child: MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: const Scaffold(
      body: SingleChildScrollView(child: SearchSection()),
    ),
  ),
);

void main() {
  setUp(() => appPrefsSnapshot = null);
  tearDown(() {
    appPrefsSnapshot = null;
    SearchService.instance.debugReindexOverride = null;
  });

  testWidgets('总开关默认关：.lrc 子开关禁用', (tester) async {
    await tester.pumpWidget(_wrap(AppPrefs()));
    await tester.pumpAndSettle();

    final switches = tester.widgetList<Switch>(find.byType(Switch)).toList();
    expect(switches, hasLength(2), reason: '总开关 + .lrc 子开关');
    expect(switches[0].value, isFalse, reason: '总开关默认关');
    expect(switches[0].onChanged, isNotNull);
    expect(switches[1].value, isFalse, reason: '.lrc 子开关默认关');
    expect(
      switches[1].onChanged,
      isNull,
      reason: '总开关关闭时 .lrc 子开关不可用（onChanged == null）',
    );
    // 关闭态：动作按钮禁用（不构造 SearchService / 不触碰 search.db）。
    expect(find.text('Rebuild index'), findsOneWidget);
    expect(find.text('Delete index'), findsOneWidget);
  });

  testWidgets('总开关开启：.lrc 子开关可用', (tester) async {
    await tester.pumpWidget(
      _wrap(AppPrefs().copyWithSearchIndex(enabled: true)),
    );
    await tester.pumpAndSettle();

    final switches = tester.widgetList<Switch>(find.byType(Switch)).toList();
    expect(switches[0].value, isTrue);
    expect(switches[1].onChanged, isNotNull);
  });

  testWidgets('总开关开启：切换 .lrc 子开关 → 写偏好 + 触发增量重建', (tester) async {
    final prefs = _Prefs(AppPrefs().copyWithSearchIndex(enabled: true));
    var reindexCalls = 0;
    SearchService.instance.debugReindexOverride = () async {
      reindexCalls++;
    };

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appPrefsProvider.overrideWith(() => prefs)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(
            body: SingleChildScrollView(child: SearchSection()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Switch).at(1));
    await tester.pumpAndSettle();

    expect(prefs.lastIndexLrc, isTrue, reason: '切换后写入 .lrc 偏好');
    expect(reindexCalls, 1, reason: '切换 .lrc 子开关触发一次增量重建（reindex）');
  });
}
