// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// [CoverSwitcher] 切换行为：
/// - fade：新旧封面交叉淡化，而不是 out-in 的「先全透明再出现」；
/// - scale / slide：仍是 out-in，离场结束前不挂载新封面；
/// - 系统关闭动画时直接换图。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:archoera_music/widgets/common/cross_fade_switcher.dart';
import 'package:archoera_music/widgets/player/cover_switcher.dart';

Widget _app({
  required ValueNotifier<int> track,
  required String style,
  bool disableAnimations = false,
}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: disableAnimations),
    child: Scaffold(
      body: Center(
        child: SizedBox(
          width: 200,
          height: 200,
          child: ValueListenableBuilder<int>(
            valueListenable: track,
            builder: (context, value, _) => CoverSwitcher(
              coverKey: value,
              style: style,
              next: true,
              child: SizedBox.expand(
                child: Center(child: Text('cover-$value')),
              ),
            ),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('fade：切歌瞬间新旧封面同时存在，结束后释放旧封面', (tester) async {
    final track = ValueNotifier(0);
    addTearDown(track.dispose);

    await tester.pumpWidget(_app(track: track, style: 'fade'));
    expect(find.text('cover-0'), findsOneWidget);
    expect(find.text('cover-1'), findsNothing);

    track.value = 1;
    await tester.pump();

    // 交叉淡化：两层同时挂载（out-in 样式此时不会出现新封面）。
    expect(find.text('cover-0'), findsOneWidget);
    expect(find.text('cover-1'), findsOneWidget);
    // 纯透明度过渡：不得再叠加位移/缩放。
    expect(
      find.descendant(
        of: find.byType(CrossFadeSwitcher),
        matching: find.byType(Transform),
      ),
      findsNothing,
    );

    double opacityOf(String text) => tester
        .widget<Opacity>(
          find
              .ancestor(of: find.text(text), matching: find.byType(Opacity))
              .first,
        )
        .opacity;

    expect(opacityOf('cover-0'), 1);
    expect(opacityOf('cover-1'), 0);

    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('cover-0'), findsOneWidget);
    expect(find.text('cover-1'), findsOneWidget);
    expect(opacityOf('cover-0'), inExclusiveRange(0, 1));
    expect(opacityOf('cover-1'), inExclusiveRange(0, 1));

    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('cover-0'), findsNothing);
    expect(find.text('cover-1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fade：新旧内容尺寸不同也不改变居中位置', (tester) async {
    final track = ValueNotifier(0);
    addTearDown(track.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              height: 300,
              child: ValueListenableBuilder<int>(
                valueListenable: track,
                builder: (context, value, _) => CoverSwitcher(
                  coverKey: value,
                  style: 'fade',
                  next: true,
                  // 模拟歌名/歌手长度不同导致的宽高差异。
                  child: SizedBox(
                    width: value == 0 ? 100 : 220,
                    height: value == 0 ? 80 : 140,
                    child: Center(child: Text('cover-$value')),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final initial = tester.getCenter(find.text('cover-0'));
    track.value = 1;
    await tester.pump();

    // 两层尺寸不同，但都必须围绕原居中位置叠放，不能出现旧封面偏移。
    expect(
      tester.getCenter(find.text('cover-0')).dx,
      moreOrLessEquals(initial.dx),
    );
    expect(
      tester.getCenter(find.text('cover-0')).dy,
      moreOrLessEquals(initial.dy),
    );
    expect(
      tester.getCenter(find.text('cover-1')).dx,
      moreOrLessEquals(initial.dx),
    );
    expect(
      tester.getCenter(find.text('cover-1')).dy,
      moreOrLessEquals(initial.dy),
    );
  });

  testWidgets('fade：关闭系统动画时直接切换', (tester) async {
    final track = ValueNotifier(0);
    addTearDown(track.dispose);

    await tester.pumpWidget(
      _app(track: track, style: 'fade', disableAnimations: true),
    );

    track.value = 1;
    await tester.pump();

    expect(find.text('cover-0'), findsNothing);
    expect(find.text('cover-1'), findsOneWidget);
  });

  testWidgets('scale：离场结束前不挂载新封面（out-in）', (tester) async {
    final track = ValueNotifier(0);
    addTearDown(track.dispose);

    await tester.pumpWidget(_app(track: track, style: 'scale'));

    track.value = 1;
    await tester.pump();

    // 离场 200ms 内只有旧封面，新封面尚未挂载。
    expect(find.text('cover-0'), findsOneWidget);
    expect(find.text('cover-1'), findsNothing);

    await tester.pump(const Duration(milliseconds: 199));
    expect(find.text('cover-0'), findsOneWidget);
    expect(find.text('cover-1'), findsNothing);

    // 离场结束后换图并开始 350ms 入场（多 1ms 避开边界取整）。
    await tester.pump(const Duration(milliseconds: 2));
    expect(find.text('cover-0'), findsNothing);
    expect(find.text('cover-1'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('cover-1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('slide：离场结束前不挂载新封面（out-in）', (tester) async {
    final track = ValueNotifier(0);
    addTearDown(track.dispose);

    await tester.pumpWidget(_app(track: track, style: 'slide'));

    track.value = 1;
    await tester.pump();

    // 离场 350ms 内只有旧封面，新封面尚未挂载。
    expect(find.text('cover-0'), findsOneWidget);
    expect(find.text('cover-1'), findsNothing);

    await tester.pump(const Duration(milliseconds: 349));
    expect(find.text('cover-0'), findsOneWidget);
    expect(find.text('cover-1'), findsNothing);

    // 离场结束后换图并开始 400ms 入场（多 1ms 避开边界取整）。
    await tester.pump(const Duration(milliseconds: 2));
    expect(find.text('cover-0'), findsNothing);
    expect(find.text('cover-1'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('cover-1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('未知样式回退 scale，仍是 out-in', (tester) async {
    final track = ValueNotifier(0);
    addTearDown(track.dispose);

    await tester.pumpWidget(_app(track: track, style: 'not-a-transition'));

    track.value = 1;
    await tester.pump();

    expect(find.text('cover-0'), findsOneWidget);
    expect(find.text('cover-1'), findsNothing);

    await tester.pump(const Duration(milliseconds: 201));
    expect(find.text('cover-0'), findsNothing);
    expect(find.text('cover-1'), findsOneWidget);
  });

  testWidgets('scale：关闭系统动画时直接切换', (tester) async {
    final track = ValueNotifier(0);
    addTearDown(track.dispose);

    await tester.pumpWidget(
      _app(track: track, style: 'scale', disableAnimations: true),
    );

    track.value = 1;
    await tester.pump();

    expect(find.text('cover-0'), findsNothing);
    expect(find.text('cover-1'), findsOneWidget);
  });
}
