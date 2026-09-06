import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/services/lyrics/lyric_line.dart';
import '../lib/widgets/player/amll_lyric_wall.dart';

void main() {
  testWidgets('AMLL 歌词墙（Canvas）能构建且无异常', (tester) async {
    final groups = [
      LyricGroup(
        original: const LyricLine(timeMs: 0, text: '第一行歌词'),
        endMs: 3000,
      ),
      LyricGroup(
        original: const LyricLine(timeMs: 3000, text: '第二行歌词'),
        translation: 'Second line',
        endMs: 6000,
      ),
      LyricGroup(
        original: const LyricLine(timeMs: 6000, text: '第三行歌词'),
        endMs: 9000,
      ),
    ];
    Widget build(int pos) => MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 500,
              child: AmllLyricWall(
                groups: groups,
                positionMs: pos,
                onSeek: (_) {},
              ),
            ),
          ),
        );
    await tester.pumpWidget(build(0));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
    expect(find.byType(AmllLyricWall), findsOneWidget);

    await tester.pumpWidget(build(3500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);
    expect(find.byType(AmllLyricWall), findsOneWidget);
  });
}
