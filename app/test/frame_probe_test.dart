// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 渲染专项 P0 基建回归测试：
/// - `FrameTimingStats` 分位数分组（合成帧时间戳，纯单测）；
/// - `BuildPaintProbe` 探针的 build/paint 计数语义；
/// - AMLL 歌词墙连续滚动「0 build / paint 有界」基线（思路参考外部合成器
///   渲染调研，见 `docs/rendering-reference-research.md` D1/D2）。
///
/// 这些断言验证的是**被消除的工作量**（headless 即可复现），不依赖真机帧时间；
/// paint 计数同时充当 D2（Retained 化）改造前的基线记录。
library;

import 'dart:ui' show FrameTiming;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:archoera_music/services/lyrics/lyric_line.dart';
import 'package:archoera_music/services/render/frame_timing_stats.dart';
import 'package:archoera_music/widgets/common/build_paint_probe.dart';
import 'package:archoera_music/widgets/player/lyrics_v7/lyrics_physics_wall.dart';

/// 合成一帧 [FrameTiming]（微秒时间戳，自 epoch 任意）。
FrameTiming fakeFrame({
  required int buildUs,
  required int rasterUs,
  int vsyncOverheadUs = 2000,
  int queueUs = 1000,
}) {
  const vsyncStart = 0;
  final buildStart = vsyncStart + vsyncOverheadUs;
  final buildFinish = buildStart + buildUs;
  final rasterStart = buildFinish + queueUs;
  final rasterFinish = rasterStart + rasterUs;
  return FrameTiming(
    vsyncStart: vsyncStart,
    buildStart: buildStart,
    buildFinish: buildFinish,
    rasterStart: rasterStart,
    rasterFinish: rasterFinish,
    rasterFinishWallTime: rasterFinish,
  );
}

/// 100 行、每行 1000ms 的规整歌词（与 amll_physics_wall_test 同构）。
List<LyricGroup> buildGroups(int count) => [
  for (var i = 0; i < count; i++)
    LyricGroup(
      original: LyricLine(timeMs: i * 1000, text: '第 $i 行'),
      endMs: (i + 1) * 1000,
    ),
];

Widget buildProbedWall(List<LyricGroup> groups, int pos) => MaterialApp(
  home: Scaffold(
    body: SizedBox(
      width: 400,
      height: 500,
      child: BuildPaintProbe(
        label: 'amll_wall',
        child: AmllPhysicsWall(
          groups: groups,
          positionMs: pos,
          onSeek: (_) {},
          playing: true,
        ),
      ),
    ),
  ),
);

void main() {
  group('FrameTimingStats', () {
    test('按族计算 avg/p50/p95/p99/max', () {
      final stats = FrameTimingStats();
      // build 1..5ms，raster 恒 8ms，队列 1/2/3/4/5ms，vsync overhead 恒 2ms。
      for (var i = 1; i <= 5; i++) {
        stats.add(
          fakeFrame(buildUs: i * 1000, rasterUs: 8000, queueUs: i * 1000),
        );
      }
      final build = stats.statsFor(FrameDurationFamily.build)!;
      expect(build.count, 5);
      expect(build.p50Us, 3000); // 最近邻秩：index round(4*0.5)=2 → 第 3 小
      expect(build.p95Us, 5000);
      expect(build.p99Us, 5000);
      expect(build.maxUs, 5000);
      expect(build.avgUs, closeTo(3000, 1e-6));

      final raster = stats.statsFor(FrameDurationFamily.raster)!;
      expect(raster.p50Us, 8000);
      expect(raster.maxUs, 8000);

      final queue = stats.statsFor(FrameDurationFamily.rasterQueue)!;
      expect(queue.p50Us, 3000);
      expect(queue.maxUs, 5000);

      final overhead = stats.statsFor(FrameDurationFamily.vsyncOverhead)!;
      expect(overhead.p50Us, 2000);
      expect(stats.statsFor(FrameDurationFamily.totalSpan), isNotNull);
    });

    test('乱序样本（rasterStart 早于 buildFinish）按 0 计入，不拉爆分位数', () {
      final stats = FrameTimingStats();
      for (var i = 1; i <= 4; i++) {
        stats.add(
          fakeFrame(buildUs: 2000, rasterUs: 4000, queueUs: i * 1000),
        );
      }
      stats.add(
        fakeFrame(buildUs: 2000, rasterUs: 4000, queueUs: -9000),
      );
      final queue = stats.statsFor(FrameDurationFamily.rasterQueue)!;
      expect(queue.count, 5);
      expect(queue.p50Us, 2000);
      expect(queue.p95Us, 4000);
      expect(queue.maxUs, 4000);
    });

    test('环形容量：只保留最近 capacity 帧', () {
      final stats = FrameTimingStats(capacity: 3);
      for (var i = 1; i <= 5; i++) {
        stats.add(fakeFrame(buildUs: i * 1000, rasterUs: 1000));
      }
      expect(stats.sampleCount, 3);
      // 最近 3 帧是 3/4/5ms。
      expect(stats.statsFor(FrameDurationFamily.build)!.p50Us, 4000);
      stats.reset();
      expect(stats.sampleCount, 0);
      expect(stats.statsFor(FrameDurationFamily.build), isNull);
    });
  });

  group('BuildPaintProbe', () {
    testWidgets('build 与 paint 分别计数，build ≠ paint', (tester) async {
      var colorA = const Color(0xFF111111);
      Widget host(Color color) => MaterialApp(
        home: Scaffold(
          body: BuildPaintProbe(
            label: 'probe_self',
            child: ColoredBox(color: color, child: const SizedBox.expand()),
          ),
        ),
      );

      await tester.pumpWidget(host(colorA));
      expect(BuildPaintProbe.buildsOf('probe_self'), 1);
      expect(BuildPaintProbe.paintsOf('probe_self'), 1);

      // 重建但视觉不变：build 计数、paint 不计数。
      await tester.pumpWidget(host(colorA));
      expect(BuildPaintProbe.buildsOf('probe_self'), 2);
      expect(BuildPaintProbe.paintsOf('probe_self'), 1);

      // 视觉变化：paint 计数。
      colorA = const Color(0xFF222222);
      await tester.pumpWidget(host(colorA));
      await tester.pump();
      expect(BuildPaintProbe.buildsOf('probe_self'), 3);
      expect(BuildPaintProbe.paintsOf('probe_self'), 2);

      expect(BuildPaintProbe.snapshot()['probe_self']!.builds, 3);
      BuildPaintProbe.resetAll();
      expect(BuildPaintProbe.buildsOf('probe_self'), 0);
      expect(BuildPaintProbe.paintsOf('probe_self'), 0);
    });
  });

  group('AMLL 歌词墙零构建基线', () {
    testWidgets('连续滚动 60 帧：0 widget build，paint 有界', (tester) async {
      final groups = buildGroups(30);
      // 播放中、位于第 2 行（2000–3000ms）中部：逐词扫亮要求每帧持续重绘。
      await tester.pumpWidget(buildProbedWall(groups, 2500));
      // 稳定挂载与首帧布局/弹簧。
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      BuildPaintProbe.resetAll();

      // 连续滚动：只推进内部 Ticker，不改 widget 配置 → 不应触发任何 build。
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      expect(
        BuildPaintProbe.buildsOf('amll_wall'),
        0,
        reason: '纯时钟推进不应重建 widget 树（连续运动与结构状态分离）',
      );
      final paints = BuildPaintProbe.paintsOf('amll_wall');
      expect(
        paints,
        inInclusiveRange(1, 60),
        reason: '播放中逐词扫亮应持续重绘；paint 数即 D2 Retained 化改造的基线',
      );
    });

    testWidgets('歌词内容不变时推进到同一行内：paint 稳定有界', (tester) async {
      final groups = buildGroups(30);
      await tester.pumpWidget(buildProbedWall(groups, 2500));
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      BuildPaintProbe.resetAll();
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final paints = BuildPaintProbe.paintsOf('amll_wall');
      // 每帧至多重绘一次本子树（无 RepaintBoundary 边界分裂）。
      expect(paints, lessThanOrEqualTo(30));
    });
  });
}
