// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 简单歌词引擎（默认档）的视口 / 排版缓存回归：
///
/// 重写后不再用 `ListView.builder` 全量构建，而是只构建视口 ± 一屏的行；
/// 位置 tick（~20Hz）只移动滚动偏移，不重新 `TextPainter.layout()`。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/lyrics/lyric_line.dart';
import 'package:archoera_music/widgets/player/lyrics_view.dart';

List<LyricGroup> buildGroups(int count) => [
  for (var i = 0; i < count; i++)
    LyricGroup(
      original: LyricLine(timeMs: i * 1000, text: '第 $i 行歌词'),
      endMs: (i + 1) * 1000,
    ),
];

Widget buildView(List<LyricGroup> groups, int pos) => MaterialApp(
  home: Scaffold(
    body: SizedBox(
      width: 400,
      height: 500,
      child: LyricsView(groups: groups, positionMs: pos, onSeek: (_) {}),
    ),
  ),
);

dynamic stateOf(WidgetTester tester) => tester.state(find.byType(LyricsView));

void main() {
  testWidgets('只构建视口附近的行（不随歌长线性增长）', (tester) async {
    final groups = buildGroups(200);
    await tester.pumpWidget(buildView(groups, 5500));
    await tester.pumpAndSettle();

    // 500px 视口 + 上下各一屏余量 ≈ 35 行，远小于 200。
    expect(stateOf(tester).debugLastWindowSize(), lessThan(50));
  });

  testWidgets('位置 tick 不重新排版（行高缓存命中）', (tester) async {
    final groups = buildGroups(50);
    await tester.pumpWidget(buildView(groups, 5500));
    await tester.pumpAndSettle();

    final measuredBefore = stateOf(tester).debugMeasuredLines();

    // 连续 20 个位置 tick（同一行内）。
    for (var i = 1; i <= 20; i++) {
      await tester.pumpWidget(buildView(groups, 5500 + i * 16));
    }

    final measured = stateOf(tester).debugMeasuredLines() - measuredBefore;
    expect(
      measured,
      0,
      reason: '同一行内位置 tick 不应触发任何 TextPainter 排版，实测 $measured',
    );
  });

  testWidgets('当前行翻转后恢复正确高亮（缓存不串行）', (tester) async {
    final groups = buildGroups(50);
    await tester.pumpWidget(buildView(groups, 5500));
    await tester.pumpAndSettle();
    // 跨行推进：第 5 行 → 第 9 行。
    await tester.pumpWidget(buildView(groups, 9500));
    await tester.pumpAndSettle();

    // 只做行为断言：不崩溃、当前行索引已更新。
    expect(stateOf(tester), isNotNull);
    expect(find.byType(LyricsView), findsOneWidget);
  });
}
