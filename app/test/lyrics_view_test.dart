// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 简易歌词引擎（LyricsView）回归测试：长行自动换行 + 可变行高滚动定位。
library;

import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
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
      width: 400,
      height: 400,
      child: LyricsView(groups: groups, positionMs: pos),
    ),
  ),
);

/// 按「去掉平衡换行符后的正文」定位歌词 Text。
Finder findLyricText(String content) => find.byWidgetPredicate(
  (widget) =>
      widget is Text &&
      (widget.data ?? widget.textSpan?.toPlainText() ?? '').replaceAll(
            '\n',
            '',
          ) ==
          content,
);

void main() {
  testWidgets('长行自动换行且不再省略号截断', (tester) async {
    final long = '长' * 200;
    final groups = buildGroups(40, longTextAt5: long);
    await tester.pumpWidget(buildView(groups, 5000));
    await tester.pumpAndSettle();

    final finder = findLyricText(long);
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

    final center = tester.getCenter(findLyricText(long));
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

  testWidgets('当前行只做轻微放大（不再 +3px）', (tester) async {
    final groups = buildGroups(3);
    await tester.pumpWidget(buildView(groups, 0));
    await tester.pumpAndSettle();

    RichText richOf(String text) => tester.widget<RichText>(
      find.descendant(of: find.text(text), matching: find.byType(RichText)),
    );
    final currentSize = richOf('第 0 行').text.style!.fontSize!;
    final otherSize = richOf('第 1 行').text.style!.fontSize!;
    expect(currentSize, closeTo(otherSize * 1.05, 1e-9));
    expect(tester.takeException(), isNull);
  });

  testWidgets('滚轮浏览时暂停跟随，3 秒后平滑回到当前行', (tester) async {
    final groups = buildGroups(50);
    await tester.pumpWidget(buildView(groups, 5500));
    await tester.pumpAndSettle();

    final scrollable = tester.state<ScrollableState>(
      find.byType(Scrollable).first,
    );
    final before = scrollable.position.pixels;

    // 模拟滚轮向下 200px（弹簧活动会发 UserScrollNotification）。
    scrollable.position.pointerScroll(200);
    await tester.pumpAndSettle();
    final scrolled = scrollable.position.pixels;
    expect(scrolled, greaterThan(before));

    // 播放推进到下一行：手动浏览期间不应被自动跟随抢回去。
    await tester.pumpWidget(buildView(groups, 6500));
    await tester.pump(const Duration(milliseconds: 200));
    expect(scrollable.position.pixels, closeTo(scrolled, 1.0));

    // 3 秒无操作后恢复跟随，当前行重新回到视口中心。
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    final center = tester.getCenter(find.text('第 6 行'));
    expect((center.dy - 200).abs(), lessThan(80));
    expect(tester.takeException(), isNull);
  });

  group('滚动预滚', () {
    test('下一行进入 500ms 窗口时提前成为滚动目标', () {
      final groups = buildGroups(10);
      expect(lyricScrollIndexAt(groups, 0), 0);
      expect(lyricScrollIndexAt(groups, 5300), 5, reason: '距下一行 700ms，仍看当前行');
      expect(lyricScrollIndexAt(groups, 5600), 6, reason: '距下一行 400ms，提前滚到下一行');
      expect(lyricScrollIndexAt(groups, 9500), 9);
    });

    test('首句之前锚定第 0 行，空歌词返回 -1', () {
      final groups = [
        LyricGroup(
          original: const LyricLine(timeMs: 3000, text: '开头'),
          endMs: 4000,
        ),
      ];
      expect(lyricScrollIndexAt(groups, 0), 0);
      expect(lyricScrollIndexAt(const <LyricGroup>[], 0), -1);
    });

    testWidgets('开唱前下一行已经滚到视口中心', (tester) async {
      final groups = buildGroups(20);
      await tester.pumpWidget(buildView(groups, 5600));
      await tester.pumpAndSettle();

      final next = tester.getCenter(find.text('第 6 行'));
      expect(
        (next.dy - 200).abs(),
        lessThan(50),
        reason: '第 6 行应在 6000ms 开唱前就位，实测 ${next.dy}',
      );
      // 高亮仍严格跟随播放位置（第 5 行此时仍在演唱，停在中心上方）。
      final current = tester.getCenter(find.text('第 5 行'));
      expect(current.dy, lessThan(200), reason: '第 5 行仍是当前行');
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('逐字长行平衡换行后仍能正常渲染', (tester) async {
    final text = '长' * 60;
    final fragments = <LyricFragment>[
      for (var i = 0; i < text.length; i++)
        LyricFragment(text: text[i], startMs: i * 100, durationMs: 100),
    ];
    final groups = [
      LyricGroup(
        original: LyricLine(timeMs: 0, text: text),
        endMs: 6000,
        fragments: fragments,
      ),
    ];
    await tester.pumpWidget(buildView(groups, 0));
    await tester.pumpAndSettle();

    final paint = find.byKey(kKaraokePaintKey);
    expect(paint, findsOneWidget);
    expect(tester.getSize(paint).height, greaterThan(30), reason: '长逐字行应换行后变高');
    expect(tester.takeException(), isNull);
  });

  group('逐字扫亮', () {
    LyricGroup groupWithFragments() => LyricGroup(
      original: const LyricLine(timeMs: 1000, text: 'AB'),
      endMs: 4000,
      fragments: const [
        LyricFragment(text: 'A', startMs: 0, durationMs: 200),
        LyricFragment(text: 'B', startMs: 1000, durationMs: 1000),
      ],
    );

    test('按片段时长线性推进，且带 80ms 预滚上限', () {
      final g = groupWithFragments();
      expect(lyricWordSweepProgress(g, g.fragments![0], 1000), 0.0);
      expect(
        lyricWordSweepProgress(g, g.fragments![0], 1100),
        closeTo(0.5, 1e-9),
      );
      expect(lyricWordSweepProgress(g, g.fragments![0], 1200), 1.0);
      // 第二个字绝对起点 2000ms，预滚 80ms → 1920ms 开始上色。
      expect(lyricWordSweepProgress(g, g.fragments![1], 1919), 0.0);
      expect(
        lyricWordSweepProgress(g, g.fragments![1], 1950),
        greaterThan(0.0),
      );
      expect(lyricWordSweepProgress(g, g.fragments![1], 3000), 1.0);
    });

    test('片段缺时长时退化为到点即亮', () {
      final g = LyricGroup(
        original: const LyricLine(timeMs: 2000, text: 'X'),
        fragments: const [LyricFragment(text: 'X', startMs: 500)],
      );
      expect(lyricWordSweepProgress(g, g.fragments!.first, 2499), 0.0);
      expect(lyricWordSweepProgress(g, g.fragments!.first, 2500), 1.0);
    });

    testWidgets('逐字扫亮是横向渐变（左亮右暗）', (tester) async {
      final group = LyricGroup(
        original: const LyricLine(timeMs: 1000, text: 'A'),
        endMs: 2000,
        fragments: const [
          LyricFragment(text: 'A', startMs: 0, durationMs: 200),
        ],
      );
      await tester.pumpWidget(buildView([group], 1100));
      await tester.pumpAndSettle();

      final paint = tester.widget<CustomPaint>(find.byKey(kKaraokePaintKey));
      final size = paint.size;
      final data = await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        paint.painter!.paint(ui.Canvas(recorder), size);
        final image = await recorder.endRecording().toImage(
          size.width.ceil(),
          size.height.ceil(),
        );
        return image.toByteData(format: ui.ImageByteFormat.rawRgba);
      });
      final stride = size.width.ceil();
      final y = (size.height / 2).floor();
      int alphaAt(int x) => data!.getUint8((y * stride + x) * 4 + 3);

      // 进度 50%，羽化 7px：左侧字已亮，右侧仍是未唱暗态。
      expect(alphaAt(2), greaterThan(alphaAt(stride - 3)));
      expect(alphaAt(stride - 3), greaterThan(0), reason: '未唱部分仍可见');
      expect(tester.takeException(), isNull);
    });

    testWidgets('片段跨行时回退到整字插值', (tester) async {
      final long = 'W' * 80;
      final group = LyricGroup(
        original: LyricLine(timeMs: 0, text: long),
        endMs: 4000,
        fragments: [LyricFragment(text: long, startMs: 0, durationMs: 1000)],
      );
      await tester.pumpWidget(buildView([group], 500));
      await tester.pumpAndSettle();

      expect(find.byKey(kKaraokePaintKey), findsNothing);
      final finder = find.byWidgetPredicate(
        (widget) => widget is RichText && widget.text.toPlainText() == long,
      );
      expect(finder, findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
