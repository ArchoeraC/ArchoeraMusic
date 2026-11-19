// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// [PlayerBarDockInset] 回归：底部让位必须跟随播放条的**真实可见性**。
///
/// 历史实现按布尔值瞬间写死 82px：拉起播放条时先空出一条占位再等条滑进来，
/// 播放页展开时条滑走了占位还留着。这里分别锚定两个因子（自身显隐 /
/// 播放页让出相位）与它们的乘积。
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/app/player_bar_dock_inset.dart';
import 'package:archoera_music/app/player_route_curves.dart';
import 'package:archoera_music/widgets/layout/player_bar.dart';

Widget _host({
  required bool visible,
  Animation<double>? routeAnimation,
  Duration duration = const Duration(milliseconds: 300),
}) => Directionality(
  textDirection: TextDirection.ltr,
  child: PlayerBarDockInset(
    visible: visible,
    routeAnimation: routeAnimation,
    duration: duration,
    child: const SizedBox(height: 100, width: 100),
  ),
);

/// 当前让位高度（取本组件最外层的 [Padding]）。
double _inset(WidgetTester tester) {
  final padding = tester
      .widgetList<Padding>(
        find.descendant(
          of: find.byType(PlayerBarDockInset),
          matching: find.byType(Padding),
        ),
      )
      .first;
  return (padding.padding as EdgeInsets).bottom;
}

void main() {
  group('PlayerBarDockInset', () {
    testWidgets('没有播放条：完全不让位', (tester) async {
      await tester.pumpWidget(_host(visible: false));
      expect(_inset(tester), 0);
    });

    testWidgets('播放条出现：让位跟着条一起长出来，不再瞬间占满', (tester) async {
      await tester.pumpWidget(_host(visible: false));
      await tester.pumpWidget(_host(visible: true));

      // 过渡中：既不是 0 也不是满值。
      await tester.pump(const Duration(milliseconds: 150));
      final middle = _inset(tester);
      expect(middle, greaterThan(0));
      expect(middle, lessThan(kDockedPlayerBarHeight));

      await tester.pumpAndSettle();
      expect(_inset(tester), kDockedPlayerBarHeight);
    });

    testWidgets('播放条收起：让位跟着收掉', (tester) async {
      await tester.pumpWidget(_host(visible: true));
      await tester.pumpWidget(_host(visible: false));
      await tester.pump(const Duration(milliseconds: 150));
      expect(_inset(tester), inExclusiveRange(0, kDockedPlayerBarHeight));
      await tester.pumpAndSettle();
      expect(_inset(tester), 0);
    });

    testWidgets('播放页让出相位内让位收掉（条走了不留占位）', (tester) async {
      await tester.pumpWidget(
        _host(visible: true, routeAnimation: const AlwaysStoppedAnimation(0)),
      );
      expect(_inset(tester), kDockedPlayerBarHeight);

      // 播放条已滑出（相位末）：占位必须归零。
      await tester.pumpWidget(
        _host(
          visible: true,
          routeAnimation: const AlwaysStoppedAnimation(kPlayerBarPhase),
        ),
      );
      expect(_inset(tester), 0);

      // 收起回到相位内：占位跟着条回位一起长回来。
      await tester.pumpWidget(
        _host(
          visible: true,
          routeAnimation: const AlwaysStoppedAnimation(kPlayerBarPhase / 2),
        ),
      );
      expect(_inset(tester), inExclusiveRange(0, kDockedPlayerBarHeight));
    });

    testWidgets('性能模式（时长 0）：直切，不演过渡', (tester) async {
      await tester.pumpWidget(_host(visible: true, duration: Duration.zero));
      await tester.pump();
      expect(_inset(tester), kDockedPlayerBarHeight);

      await tester.pumpWidget(_host(visible: false, duration: Duration.zero));
      await tester.pump();
      expect(_inset(tester), 0);
    });
  });
}
