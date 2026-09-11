// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// AMLL 物理歌词墙（lyrics_v7）回归测试：锚点/高亮分离、seek 与高速换行。
///
/// 覆盖以下历史 Bug：
/// - 播放位置无行覆盖（前奏 / 间隙 / 末尾）时错误回退到首行；
/// - 高速换行 / 跳转时行距塌陷、重叠；
/// - seek 过程中再次换行打断整墙位移造成瞬移。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/lyrics/lyric_line.dart';
import 'package:archoera_music/widgets/player/lyrics_v7/lyrics_physics_wall.dart';
import 'package:archoera_music/widgets/player/lyrics_v7/spring.dart';

/// 100 行、每行 1000ms 的规整歌词。
List<LyricGroup> buildGroups(int count) => [
  for (var i = 0; i < count; i++)
    LyricGroup(
      original: LyricLine(timeMs: i * 1000, text: '第 $i 行'),
      endMs: (i + 1) * 1000,
    ),
];

Widget buildWall(List<LyricGroup> groups, int pos) => MaterialApp(
  home: Scaffold(
    body: SizedBox(
      width: 400,
      height: 500,
      child: AmllPhysicsWall(groups: groups, positionMs: pos, onSeek: (_) {}),
    ),
  ),
);

dynamic stateOf(WidgetTester tester) =>
    tester.state(find.byType(AmllPhysicsWall));

Future<void> settle(WidgetTester tester, {int frames = 90}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  testWidgets('前奏无覆盖时锚定首行而非越界', (tester) async {
    final groups = [
      LyricGroup(
        original: const LyricLine(timeMs: 5000, text: '第一句'),
        endMs: 6000,
      ),
      LyricGroup(
        original: const LyricLine(timeMs: 6000, text: '第二句'),
        endMs: 7000,
      ),
    ];
    await tester.pumpWidget(buildWall(groups, 0));
    await settle(tester);
    final s = stateOf(tester);
    expect((s as dynamic).debugActive(), -1);
    expect(s.debugAnchor(), 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('正常播放锚点跟随激活行', (tester) async {
    final groups = buildGroups(100);
    await tester.pumpWidget(buildWall(groups, 0));
    await settle(tester);
    dynamic s = stateOf(tester);
    expect(s.debugAnchor(), 0);

    await tester.pumpWidget(buildWall(groups, 5000));
    await settle(tester);
    s = stateOf(tester);
    expect(s.debugActive(), 5);
    expect(s.debugAnchor(), 5);
  });

  testWidgets('末尾越界保持末行，不回退首行', (tester) async {
    final groups = buildGroups(20);
    await tester.pumpWidget(buildWall(groups, 19 * 1000 + 200));
    await settle(tester);
    dynamic s = stateOf(tester);
    expect(s.debugAnchor(), 19);

    // 越过末行结束时间：无覆盖但未触发 seek 阈值 → 保持末行。
    await tester.pumpWidget(buildWall(groups, 20 * 1000 + 500));
    await settle(tester);
    s = stateOf(tester);
    expect(s.debugActive(), -1);
    expect(s.debugAnchor(), 19);
  });

  testWidgets('大幅前进 seek 后行距保持、无重叠', (tester) async {
    final groups = buildGroups(100);
    await tester.pumpWidget(buildWall(groups, 0));
    await settle(tester);
    await tester.pumpWidget(buildWall(groups, 80000)); // line 80
    await settle(tester);

    final s = stateOf(tester);
    final y = (s as dynamic).debugY() as List<double>;
    final centers = s.debugCenters() as List<double>;
    expect(s.debugAnchor(), 80);

    // 锚点行对齐 align*H（默认 0.5*500=250）。
    expect(y[80], closeTo(250, 1.0));
    // 全部行间距严格递增且等于自然中心间距。
    for (var i = 1; i < y.length; i++) {
      expect(y[i] - y[i - 1], closeTo(centers[i] - centers[i - 1], 0.5));
    }
  });

  testWidgets('大幅回退 seek 后锚点与行距正确', (tester) async {
    final groups = buildGroups(100);
    await tester.pumpWidget(buildWall(groups, 80000));
    await settle(tester);
    await tester.pumpWidget(buildWall(groups, 4000)); // line 4
    await settle(tester);

    final s = stateOf(tester);
    final y = (s as dynamic).debugY() as List<double>;
    expect(s.debugAnchor(), 4);
    expect(y[4], closeTo(250, 1.0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('高速换行期间锚点始终跟随、无异常', (tester) async {
    final groups = buildGroups(400);
    await tester.pumpWidget(buildWall(groups, 0));
    await settle(tester);

    // 每帧前进 400ms（低于 2000ms seek 阈值，走级联路径）。
    var pos = 0;
    for (var i = 0; i < 120; i++) {
      pos += 400;
      await tester.pumpWidget(buildWall(groups, pos));
      await tester.pump(const Duration(milliseconds: 16));
    }
    final s = stateOf(tester);
    expect(s.debugAnchor(), ((pos ~/ 1000)).clamp(0, 399));
    expect(tester.takeException(), isNull);
  });

  testWidgets('高速换行时上方行不堆叠（可见行保持单调递增）', (tester) async {
    final groups = buildGroups(400);
    await tester.pumpWidget(buildWall(groups, 0));
    await settle(tester);

    var pos = 0;
    for (var step = 0; step < 160; step++) {
      pos += 400;
      await tester.pumpWidget(buildWall(groups, pos));
      // 仅推进一帧，模拟“未 settle 就换下一行”的高速状态。
      await tester.pump(const Duration(milliseconds: 16));
      final y = (stateOf(tester) as dynamic).debugY() as List<double>;
      final visible = <double>[];
      for (final v in y) {
        if (v > -80 && v < 580) visible.add(v);
      }
      for (var k = 1; k < visible.length; k++) {
        expect(
          visible[k],
          greaterThan(visible[k - 1] + 0.5),
          reason: 'step $step 可见行重叠/交叉：$visible',
        );
      }
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('seek 位移途中再次换行不瞬移', (tester) async {
    final groups = buildGroups(100);
    await tester.pumpWidget(buildWall(groups, 0));
    await settle(tester);
    // 大跳
    await tester.pumpWidget(buildWall(groups, 90000));
    await tester.pump(const Duration(milliseconds: 16));
    final s = stateOf(tester);
    final midY = ((s as dynamic).debugY() as List<double>)[90];
    // 位移进行中：锚点行尚未到达终位。
    expect(midY, isNot(closeTo(250, 0.5)));

    // 位移途中换到下一行（+1000ms，delta 小，不触发 seek）。
    await tester.pumpWidget(buildWall(groups, 91000));
    await tester.pump(const Duration(milliseconds: 16));
    final s2 = stateOf(tester);
    final afterY = ((s2 as dynamic).debugY() as List<double>)[90];
    // 连续：不应出现一帧内的巨大瞬移。
    expect((afterY - midY).abs(), lessThan(400));
    expect(tester.takeException(), isNull);
  });

  testWidgets('超长歌词自动换行（行高 > 单行，不再省略号截断）', (tester) async {
    final groups = [
      LyricGroup(
        original: const LyricLine(
          timeMs: 0,
          text: '一二三四五六七八九十一二三四五六七八九十一二三四五六七八九十一二三四五六七八九十一二三四五六七八九十',
        ),
        endMs: 10000,
      ),
    ];
    await tester.pumpWidget(buildWall(groups, 0));
    await settle(tester);
    final heights = (stateOf(tester) as dynamic).debugHeights() as List<double>;
    // 默认字号 18、可用宽约 376 → 每行约 20 字，50 字应换行为多行。
    expect(heights.single, greaterThan(30.0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('段落缓存随视口有界（不随歌长增长）', (tester) async {
    final groups = buildGroups(600);
    await tester.pumpWidget(buildWall(groups, 300 * 1000));
    await settle(tester);
    dynamic s = stateOf(tester);
    final entries = s.debugCacheEntries() as int;
    // 视口 500 高、行高约 50 → 可见约 12~16 行；只缓存可见窗口。
    expect(entries, greaterThan(0));
    expect(entries, lessThan(60));

    // 大跳后仍不增长（内存 O(视口)，与歌长无关）。
    await tester.pumpWidget(buildWall(groups, 550 * 1000));
    await settle(tester);
    s = stateOf(tester);
    expect(s.debugCacheEntries() as int, lessThan(60));
    expect(tester.takeException(), isNull);
  });

  testWidgets('逐字扫亮活跃行渲染无异常（不缓存路径）', (tester) async {
    final groups = [
      LyricGroup(
        original: const LyricLine(timeMs: 0, text: '逐字高亮'),
        endMs: 5000,
        fragments: const [
          LyricFragment(text: '逐', startMs: 0, durationMs: 1000),
          LyricFragment(text: '字', startMs: 1000, durationMs: 1000),
          LyricFragment(text: '高', startMs: 2000, durationMs: 1000),
          LyricFragment(text: '亮', startMs: 3000, durationMs: 1000),
        ],
      ),
      LyricGroup(
        original: const LyricLine(timeMs: 5000, text: '下一行'),
        endMs: 9000,
      ),
    ];
    await tester.pumpWidget(buildWall(groups, 500));
    await settle(tester);
    expect(tester.takeException(), isNull);
  });

  group('Spring1D 延迟语义', () {
    test('延迟期间继续朝当前目标运动，不冻结', () {
      final s = Spring1D();
      s.hardSet(0);
      s.setTarget(100);
      for (var i = 0; i < 5; i++) {
        s.update(0.01);
      }
      final moved = s.current;
      expect(moved, greaterThan(0));
      expect(moved, lessThan(100));

      // 排队一个较远的延迟目标：延迟未到期时仍应向 100 继续运动。
      s.setTarget(1000, delayMs: 500);
      s.update(0.01);
      expect(s.current, greaterThan(moved));
      expect(s.current, lessThan(1000));

      // 延迟到期后转向新目标。
      for (var i = 0; i < 60; i++) {
        s.update(0.01);
      }
      expect(s.targetPosition, 1000);
    });
  });
}
