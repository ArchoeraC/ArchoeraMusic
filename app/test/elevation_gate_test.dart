// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 提权启动防呆门：两个决策出口 + 提权形态文案。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/app/elevation_gate.dart';
import 'package:archoera_music/l10n/generated/app_localizations.dart';
import 'package:archoera_music/services/platform/process_elevation.dart';
import 'package:archoera_music/theme/app_theme.dart';

const _locale = Locale('zh', 'CN');

Widget _host(ProcessElevation elevation, ValueChanged<bool> onDecision) {
  return MaterialApp(
    locale: _locale,
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      ...GlobalMaterialLocalizations.delegates,
    ],
    theme: buildAppTheme(AppPalette.dark, Brightness.dark),
    home: ElevationGatePage(elevation: elevation, onDecision: onDecision),
  );
}

const _admin = ProcessElevation(
  elevated: true,
  kind: ProcessElevationKind.administrator,
);

void main() {
  test('原生返回值映射：0/1/2 与失败降级', () {
    expect(ProcessElevation.fromNative(0)?.elevated, isFalse);
    expect(ProcessElevation.fromNative(1)?.kind, ProcessElevationKind.root);
    expect(
      ProcessElevation.fromNative(2)?.kind,
      ProcessElevationKind.administrator,
    );
    // 探测失败（<0）不是提权，也不是「已提权但形态未知」。
    expect(ProcessElevation.fromNative(-1), isNull);
    expect(ProcessElevation.fromNative(-2), isNull);
  });

  testWidgets('默认出口是「退出」，点击返回 false（不放行）', (tester) async {
    bool? decision;
    await tester.pumpWidget(_host(_admin, (v) => decision = v));

    await tester.tap(find.byKey(const ValueKey('elevation-gate-exit')));
    await tester.pump();

    expect(decision, isFalse);
  });

  testWidgets('显式点击「仍要继续」才返回 true', (tester) async {
    bool? decision;
    await tester.pumpWidget(_host(_admin, (v) => decision = v));

    await tester.tap(find.byKey(const ValueKey('elevation-gate-continue')));
    await tester.pump();

    expect(decision, isTrue);
  });

  testWidgets('Windows 管理员形态显示对应文案', (tester) async {
    await tester.pumpWidget(_host(_admin, (_) {}));

    final l10n = lookupAppLocalizations(_locale);
    expect(
      find.text(
        l10n.elevationGateBody(kind: l10n.elevationGateKindAdministrator),
      ),
      findsOneWidget,
    );
  });

  testWidgets('POSIX root 形态显示对应文案', (tester) async {
    await tester.pumpWidget(
      _host(
        const ProcessElevation(elevated: true, kind: ProcessElevationKind.root),
        (_) {},
      ),
    );

    final l10n = lookupAppLocalizations(_locale);
    expect(
      find.text(l10n.elevationGateBody(kind: l10n.elevationGateKindRoot)),
      findsOneWidget,
    );
  });
}
