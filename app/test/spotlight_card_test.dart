// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 首页「随机聚光」卡片冒烟测试：挂载 / 加载 / 换一批不抛异常。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/l10n/generated/app_localizations.dart';
import 'package:archoera_music/widgets/home/spotlight_card.dart';

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
}
