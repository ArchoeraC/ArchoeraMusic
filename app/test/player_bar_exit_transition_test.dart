// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// [PlayerBarExitTransition] 独立测试：播放条只在路由动画的前
/// [kPlayerBarPhase] 段让出（展开先滑出、收起最后回位），相位之外保持
/// 完全隐藏；让出过程中不再截获点击；性能模式直切。
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/app/player_bar_exit_transition.dart';
import 'package:archoera_music/app/player_route_curves.dart';

Widget _host(double value, {bool disableAnimations = false}) => Directionality(
  textDirection: TextDirection.ltr,
  child: Stack(
    children: [
      PlayerBarExitTransition(
        animation: AlwaysStoppedAnimation<double>(value),
        disableAnimations: disableAnimations,
        child: const SizedBox(height: 82, width: 100, child: Text('bar')),
      ),
    ],
  ),
);

void main() {
  group('playerBarExitProgress', () {
    test('相位外：0 时刻完全可见，相位结束即完全让开', () {
      expect(playerBarExitProgress(0), 0);
      expect(playerBarExitProgress(kPlayerBarPhase), 1);
      expect(playerBarExitProgress(1), 1);
      expect(playerBarExitProgress(kPlayerBarPhase / 2), inExclusiveRange(0, 1));
    });

    test('展开相位确实短于整段转场（播放页主体动作留给后半段）', () {
      expect(kPlayerBarPhase, inExclusiveRange(0, 0.5));
      expect(
        kPlayerRouteTransitionDuration,
        kPlayerBarExitDuration + kPlayerRouteSlideDuration,
        reason: '总时长必须等于「播放条让出 + 播放页滑动」，否则相位比例会漂移',
      );
    });
  });

  group('PlayerBarExitTransition', () {
    testWidgets('折叠态（动画值 0）完全可见且可点击', (tester) async {
      await tester.pumpWidget(_host(0));
      expect(find.text('bar'), findsOneWidget);
      expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, 1);
      expect(
        tester.widget<FractionalTranslation>(find.byType(FractionalTranslation)).translation,
        Offset.zero,
      );
      expect(tester.widget<IgnorePointer>(find.byType(IgnorePointer)).ignoring, isFalse);
    });

    testWidgets('播放条相位内滑出并淡出，且不再截获点击', (tester) async {
      await tester.pumpWidget(_host(kPlayerBarPhase));
      expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, 0);
      expect(
        tester.widget<FractionalTranslation>(find.byType(FractionalTranslation)).translation,
        const Offset(0, 1),
      );
      expect(tester.widget<IgnorePointer>(find.byType(IgnorePointer)).ignoring, isTrue);
    });

    testWidgets('页面滑动段（动画值 1）保持让开状态', (tester) async {
      await tester.pumpWidget(_host(1));
      expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, 0);
      expect(tester.widget<IgnorePointer>(find.byType(IgnorePointer)).ignoring, isTrue);
    });

    testWidgets('性能模式直切：不演让出（播放页第一帧已盖住）', (tester) async {
      await tester.pumpWidget(_host(1, disableAnimations: true));
      expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, 1);
      expect(tester.widget<IgnorePointer>(find.byType(IgnorePointer)).ignoring, isFalse);
    });
  });
}
