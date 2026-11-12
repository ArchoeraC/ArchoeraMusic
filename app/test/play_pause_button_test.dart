// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 播放/暂停胶囊键（[PlayPauseButton]）的观感与交互契约：
/// - 形状是椭圆（横向长于纵向），不再是纯圆形；
/// - 字形随播放状态切换（三角 / 双竖线），缓冲时换成进度圈；
/// - 无内容时不可点，有内容时点击回调 toggle。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:archoera_music/widgets/player/play_pause_button.dart';
import 'package:archoera_music/eta/icon/eta_icons.dart';

Future<void> _pump(
  WidgetTester tester, {
  required bool playing,
  bool buffering = false,
  VoidCallback? onPressed,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: PlayPauseButton(
            playing: playing,
            buffering: buffering,
            onPressed: onPressed,
            tooltip: '播放/暂停',
          ),
        ),
      ),
    ),
  );
  // 缓冲态含无限循环的进度圈，不能用 pumpAndSettle。
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('形状为椭圆：横向长于纵向，且主题色实心底', (tester) async {
    await _pump(tester, playing: false, onPressed: () {});
    final size = tester.getSize(find.byType(PlayPauseButton));
    expect(size.width, greaterThan(size.height));
    expect(
      size.width / size.height,
      closeTo(PlayPauseButton.widthFactor, 0.001),
    );
    final pill = tester.widget<AnimatedContainer>(
      find.descendant(
        of: find.byType(PlayPauseButton),
        matching: find.byType(AnimatedContainer),
      ),
    );
    final decoration = pill.decoration! as BoxDecoration;
    final scheme = Theme.of(tester.element(find.byType(PlayPauseButton)))
        .colorScheme;
    expect(decoration.color, scheme.primary);
  });

  testWidgets('字形随播放状态切换', (tester) async {
    await _pump(tester, playing: false, onPressed: () {});
    expect(find.byIcon(EtaIcons.play), findsOneWidget);

    await _pump(tester, playing: true, onPressed: () {});
    expect(find.byIcon(EtaIcons.pause), findsOneWidget);
    expect(find.byIcon(EtaIcons.play), findsNothing);
  });

  testWidgets('缓冲中显示进度圈且不可点', (tester) async {
    var taps = 0;
    await _pump(
      tester,
      playing: true,
      buffering: true,
      onPressed: () => taps++,
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byIcon(EtaIcons.pause), findsNothing);
    await tester.tap(find.byType(PlayPauseButton));
    expect(taps, 0);
  });

  testWidgets('有内容时点击触发回调，无内容时禁用', (tester) async {
    var taps = 0;
    await _pump(tester, playing: false, onPressed: () => taps++);
    await tester.tap(find.byType(PlayPauseButton));
    expect(taps, 1);

    await _pump(tester, playing: false);
    await tester.tap(find.byType(PlayPauseButton));
    expect(taps, 1);
    // 禁用态压成低对比，避免看起来像可点的实心主色按钮。
    final pill = tester.widget<AnimatedContainer>(
      find.descendant(
        of: find.byType(PlayPauseButton),
        matching: find.byType(AnimatedContainer),
      ),
    );
    final scheme = Theme.of(tester.element(find.byType(PlayPauseButton)))
        .colorScheme;
    expect((pill.decoration! as BoxDecoration).color, isNot(scheme.primary));
  });
}
