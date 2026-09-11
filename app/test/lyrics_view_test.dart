// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 简易歌词引擎（LyricsView）回归测试：长行自动换行 + 可变行高滚动定位。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/lyrics/lyric_line.dart';
import 'package:archoera_music/widgets/player/lyrics_view.dart';

List<LyricGroup> buildGroups(int count, {String? longTextAt5}) => [
  for (var i = 0; i < count; i++)
    LyricGroup(
      original: LyricLine(
        timeMs: i * 1000,
        text: i == 5 ? (longTextAt5 ?? '第 $i 行') : '第 $i 行',
      ),
      endMs: (i + 1) * 1000,
    ),
];

Widget buildView(List<LyricGroup> groups, int pos) => MaterialApp(
  home: Scaffold(
    body: SizedBox(
      height: 400,
      child: LyricsView(groups: groups, positionMs: pos),
    ),
  ),
);

void main() {
  testWidgets('长行自动换行且不再省略号截断', (tester) async {
    final long = '长' * 200;
    final groups = buildGroups(40, longTextAt5: long);
    await tester.pumpWidget(buildView(groups, 5000));
    await tester.pumpAndSettle();

    final finder = find.text(long);
    expect(finder, findsOneWidget);
    final text = tester.widget<Text>(finder);
    expect(text.maxLines, isNull, reason: '不应再限制单行');
    expect(text.overflow, isNull, reason: '不应再省略号截断');
    // 换行后高度明显大于单行。
    expect(tester.getSize(finder).height, greaterThan(30));
    expect(tester.takeException(), isNull);
  });

  testWidgets('可变行高下当前行仍定位到视口中心', (tester) async {
    final long = '长' * 200;
    final groups = buildGroups(40, longTextAt5: long);
    await tester.pumpWidget(buildView(groups, 5000));
    await tester.pumpAndSettle();

    final center = tester.getCenter(find.text(long));
    expect((center.dy - 200).abs(), lessThan(80), reason: '当前行应居中');
    expect(tester.takeException(), isNull);
  });

  testWidgets('跳转到靠后行仍能正确定位（懒加载下按实测偏移滚动）', (tester) async {
    final groups = buildGroups(60);
    await tester.pumpWidget(buildView(groups, 0));
    await tester.pumpAndSettle();
    await tester.pumpWidget(buildView(groups, 40000)); // 第 40 行
    await tester.pumpAndSettle();

    final finder = find.text('第 40 行');
    expect(finder, findsOneWidget);
    final center = tester.getCenter(finder);
    expect((center.dy - 200).abs(), lessThan(80));
    expect(tester.takeException(), isNull);
  });
}
