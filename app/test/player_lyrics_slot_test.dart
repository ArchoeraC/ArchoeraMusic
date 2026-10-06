// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// 播放页歌词槽动效/生命周期回归：
//   - 打开：自下而上滑入；
//   - 关闭：**向下滑出**，动画结束后**卸载**（不再保留不可见歌词墙）；
//   - 隐藏时不构建歌词（无占位闪烁）。

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/widgets/player/player_lyrics_slot.dart';

void main() {
  const key = ValueKey<String>('lyrics-child');

  Widget host({required bool visible, bool enabled = true}) => MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 400,
        height: 400,
        child: PlayerLyricsSlot(
          visible: visible,
          enabled: enabled,
          builder: (_) => const SizedBox.expand(
            key: key,
            child: ColoredBox(color: Color(0xFFFF0000)),
          ),
        ),
      ),
    ),
  );

  testWidgets('打开：自下而上滑入并最终归位', (tester) async {
    await tester.pumpWidget(host(visible: false));
    await tester.pump();
    expect(find.byKey(key), findsNothing);

    await tester.pumpWidget(host(visible: true));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(key), findsOneWidget);
    final mid = tester.getTopLeft(find.byKey(key)).dy;
    expect(mid, greaterThan(1), reason: '进场应从下方滑入（尚未归位）');

    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byKey(key)).dy, moreOrLessEquals(0, epsilon: 0.5));
  });

  testWidgets('关闭：向下滑出，动画结束后卸载', (tester) async {
    await tester.pumpWidget(host(visible: true));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byKey(key)).dy, moreOrLessEquals(0, epsilon: 0.5));

    await tester.pumpWidget(host(visible: false));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(key), findsOneWidget, reason: '滑出过程仍可见');
    expect(
      tester.getTopLeft(find.byKey(key)).dy,
      greaterThan(1),
      reason: '关闭应向下滑动（而非仅淡出/瞬隐）',
    );

    await tester.pumpAndSettle();
    expect(find.byKey(key), findsNothing, reason: '关闭后应卸载歌词组件');
  });

  testWidgets('隐藏时不构建歌词（builder 不被调用）', (tester) async {
    var built = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayerLyricsSlot(
            visible: false,
            enabled: true,
            builder: (_) {
              built++;
              return const SizedBox.expand(key: key);
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(key), findsNothing);
    expect(built, 0);
  });

  testWidgets('enabled=false 立即隐藏（无歌词/未挂载）', (tester) async {
    await tester.pumpWidget(host(visible: true, enabled: false));
    await tester.pumpAndSettle();
    expect(find.byKey(key), findsNothing);
  });
}
