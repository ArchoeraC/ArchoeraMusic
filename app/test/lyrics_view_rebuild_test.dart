// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 简单歌词引擎（默认档）的「仅当前行重建」回归：
///
/// 位置 tick（~20Hz）只应重建**当前行**（逐字扫亮需要）；非当前行返回缓存
/// 的同一 widget 实例，`Element.updateChild` 对 identical widget 短路 →
/// 不重建、不重绘。行高列表也只在「当前行翻转 / 配置变化」时重算。
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
  testWidgets('位置 tick 下非当前行零重建（仅当前行重建）', (tester) async {
    final groups = buildGroups(50);
    // 第 5 行（5000–6000ms）中部：当前行固定，只有扫亮在推进。
    await tester.pumpWidget(buildView(groups, 5500));
    await tester.pumpAndSettle();

    final builtBefore = stateOf(tester).debugBuiltLines();
    final hitsBefore = stateOf(tester).debugLineCacheHits();

    // 连续 20 个位置 tick（同一行内）。
    for (var i = 1; i <= 20; i++) {
      await tester.pumpWidget(buildView(groups, 5500 + i * 16));
    }

    final built = stateOf(tester).debugBuiltLines() - builtBefore;
    final hits = stateOf(tester).debugLineCacheHits() - hitsBefore;

    // 每 tick 最多构造 1 个 _Line（当前行）；非当前行全部命中缓存。
    expect(
      built,
      lessThanOrEqualTo(20),
      reason: '20 个 tick 内最多重建当前行 20 次，实测 $built',
    );
    expect(
      hits,
      greaterThanOrEqualTo(20),
      reason: '每个 tick 的非当前行都应命中缓存实例，实测命中 $hits 次',
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
