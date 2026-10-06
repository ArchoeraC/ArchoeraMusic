// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 首页「随机聚光」卡片冒烟测试：挂载 / 加载 / 换一批不抛异常。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/l10n/generated/app_localizations.dart';
import 'package:archoera_music/services/netease/track.dart';
import 'package:archoera_music/services/spotlight/spotlight.dart';
import 'package:archoera_music/stores/spotlight_provider.dart';
import 'package:archoera_music/widgets/home/spotlight_card.dart';

/// 注入固定 pick 的聚光控制器（不触发真实来源汇总，专注渲染）。
class _FixedSpotlight extends SpotlightNotifier {
  _FixedSpotlight(this._pick);
  final SpotlightPick _pick;

  @override
  SpotlightState build() =>
      SpotlightState(pick: _pick, ready: true, lastSource: _pick.source);

  @override
  Future<void> ensure() async {}

  @override
  Future<void> reroll() async {}
}

Widget _host({VoidCallback? onOpenDaily}) => ProviderScope(
  child: MaterialApp(
    localizationsDelegates: const [AppLocalizations.delegate],
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: HomeSpotlightCard(onOpenDaily: onOpenDaily ?? () {}),
      ),
    ),
  ),
);

void main() {
  testWidgets('挂载与加载阶段不抛异常', (tester) async {
    await tester.pumpWidget(_host());
    // 首帧 → 触发 ensure（post-frame）；多帧推进让异步来源汇总完成。
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏渲染不溢出（预览区隐藏）', (tester) async {
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_host());
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('大池子 4 位序号预览行不溢出（编号自适应宽度）', (tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final tracks = [
      for (var i = 0; i < 5000; i++)
        Track(id: '$i', title: '曲 $i', source: 'local', artists: const []),
    ];
    // 起始曲下标 4996 → 预览序号 4998/4999/5000（4 位数）。
    final pick = SpotlightPick(
      source: SpotlightSource.local,
      tracks: tracks,
      leadIndex: 4996,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          spotlightProvider.overrideWith(() => _FixedSpotlight(pick)),
        ],
        child: MaterialApp(
          localizationsDelegates: const [AppLocalizations.delegate],
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: HomeSpotlightCard(onOpenDaily: () {}),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('5000'), findsOneWidget);
    // 关键回归：4 位序号宽度须超过旧的固定 22px（否则溢出裁切）。
    expect(tester.getSize(find.text('5000')).width, greaterThan(22));
  });
}
