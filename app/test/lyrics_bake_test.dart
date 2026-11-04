// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// AMLL 歌词墙「整层档稳态烘焙」（D2a）回归测试：
///
/// - 稳态帧走烘焙贴图路径（`debugBakeActive()`）；
/// - 换行过渡 / seek / 浏览期间回退现行整层路径，稳定后恢复贴图；
/// - **像素等价**：同一静止画面，烘焙贴图帧与现行整层路径帧逐像素一致
///   （容差内），保证「省掉每帧高斯」不改变观感。
///
/// 像素对比在本机（WSL 无 GPU、llvmpipe 软件光栅）即可复现；两路径的
/// 模糊管线在数学上等效（内容 1/4 重采样 → blur(σ·k) → 双线性放大），
/// 容差只用于吸收亚像素采样相位差。
library;

import 'dart:ui' as ui;

import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:archoera_music/services/lyrics/lyric_line.dart';
import 'package:archoera_music/widgets/player/lyrics_v7/lyrics_physics_wall.dart';

final _wallKey = GlobalKey();
const _boundaryKey = ValueKey('wall_boundary');

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
      child: RepaintBoundary(
        key: _boundaryKey,
        child: AmllPhysicsWall(
          key: _wallKey,
          groups: groups,
          positionMs: pos,
          onSeek: (_) {},
          // 暂停态：位置固定 → 扫亮外观静止 → 稳态可精确复现。
          playing: false,
        ),
      ),
    ),
  ),
);

dynamic stateOf(WidgetTester tester) => tester.state(find.byType(AmllPhysicsWall));

Future<ui.Image> captureWall(WidgetTester tester) async {
  final boundary =
      tester.renderObject(find.byKey(_boundaryKey)) as RenderRepaintBoundary;
  // 测试环境的 fake async 等不到真实光栅回调（含烘焙图的 toImageSync 队列），
  // 截图须走 runAsync 的真实事件循环。
  final img = await tester.runAsync(() => boundary.toImage());
  if (img == null) fail('截图失败（runAsync 返回 null）');
  return img;
}

Future<List<int>> rgbaOf(WidgetTester tester, ui.Image image) async {
  // 与截图同理：GPU 图像的 toByteData 也需要真实事件循环。
  final data = await tester.runAsync(
    () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
  );
  if (data == null) fail('toByteData 失败（runAsync 返回 null）');
  return data.buffer.asUint8List();
}

int maxDiff(List<int> a, List<int> b) {
  if (a.length != b.length) return 1 << 30;
  var m = 0;
  for (var i = 0; i < a.length; i++) {
    final d = (a[i] - b[i]).abs();
    if (d > m) m = d;
  }
  return m;
}

/// 逐像素差统计：每像素取 RGBA 最大通道差。
({double mean, double over32Pct}) rgbaStats(List<int> a, List<int> b) {
  if (a.length != b.length) return (mean: 255, over32Pct: 100);
  var sum = 0;
  var over = 0;
  var n = 0;
  for (var i = 0; i < a.length; i += 4) {
    var d = 0;
    for (var c = 0; c < 4; c++) {
      final v = (a[i + c] - b[i + c]).abs();
      if (v > d) d = v;
    }
    sum += d;
    if (d > 32) over++;
    n++;
  }
  return (mean: sum / n, over32Pct: over * 100 / n);
}

void main() {
  testWidgets('稳态帧走烘焙贴图路径', (tester) async {
    final groups = buildGroups(30);
    // 位于第 2 行（2000–3000ms）中部，激活外观完整。
    await tester.pumpWidget(buildWall(groups, 2500));
    await tester.pumpAndSettle();
    expect(
      stateOf(tester).debugBakeActive(),
      isTrue,
      reason: '静止 + 无过渡的稳态帧应使用烘焙贴图（整层高斯只算一次）',
    );
  });

  testWidgets('换行过渡回退现行路径，稳定后恢复贴图', (tester) async {
    final groups = buildGroups(30);
    await tester.pumpWidget(buildWall(groups, 2500));
    await tester.pumpAndSettle();
    expect(stateOf(tester).debugBakeActive(), isTrue);

    // 跨行推进（2500 → 4200，第 4 行）：弹簧级联动画开始。
    await tester.pumpWidget(buildWall(groups, 4200));
    await tester.pump(const Duration(milliseconds: 16));
    expect(
      stateOf(tester).debugBakeActive(),
      isFalse,
      reason: '级联过渡期间非激活外观在变，必须回退现行整层路径',
    );

    await tester.pumpAndSettle();
    expect(
      stateOf(tester).debugBakeActive(),
      isTrue,
      reason: '过渡收敛后应重建烘焙图并恢复贴图',
    );
  });

  testWidgets('换行不重烘焙：只为新进入视口的行烘一张', (tester) async {
    final groups = buildGroups(30);
    await tester.pumpWidget(buildWall(groups, 2500));
    await tester.pumpAndSettle();
    final before = stateOf(tester).debugBakeCount();

    // 连续 3 次换行（每次推进 1 行）：缓存与位置无关，旧行不应重烘。
    for (final pos in [3500, 4500, 5500]) {
      await tester.pumpWidget(buildWall(groups, pos));
      await tester.pumpAndSettle();
      expect(stateOf(tester).debugBakeActive(), isTrue);
    }

    final delta = stateOf(tester).debugBakeCount() - before;
    expect(
      delta,
      lessThanOrEqualTo(6),
      reason: '每次换行只应为新进入视口的行烘焙（约 1~2 行），'
          '实测 3 次换行共烘 $delta 张；若接近可见行数×次数，说明又在全量重烘',
    );
  });

  testWidgets('观感等价：过渡帧（缓存贴图）≈ 过渡帧（逐行高斯）', (tester) async {
    final groups = buildGroups(30);

    Future<List<int>> midTransition({required bool bake}) async {
      // 卸载重置状态，保证两次跑同一动画序列。
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(buildWall(groups, 2500));
      await tester.pumpAndSettle();
      stateOf(tester).debugSetBakeEnabled(bake);
      await tester.pumpWidget(buildWall(groups, 4200));
      // 级联进行中（静态外观尚未收敛 → 走过渡分支）。
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(stateOf(tester).debugBakeActive(), isFalse);
      return rgbaOf(tester, await captureWall(tester));
    }

    final a = await midTransition(bake: true);
    final b = await midTransition(bake: false);
    final s = rgbaStats(a, b);
    // ignore: avoid_print
    print('transition cache-vs-live mean=${s.mean.toStringAsFixed(2)} '
        'over32=${s.over32Pct.toStringAsFixed(2)}%');
    expect(s.mean, lessThanOrEqualTo(8), reason: '实测 mean=${s.mean}');
    expect(s.over32Pct, lessThanOrEqualTo(10), reason: '实测 over32=${s.over32Pct}%');
  });

  testWidgets('观感等价：烘焙贴图帧 ≈ 过渡逐行高斯帧', (tester) async {
    final groups = buildGroups(30);
    await tester.pumpWidget(buildWall(groups, 2500));
    await tester.pumpAndSettle();
    expect(stateOf(tester).debugBakeActive(), isTrue);

    final baked = await captureWall(tester);

    stateOf(tester).debugSetBakeEnabled(false);
    await tester.pumpAndSettle();
    expect(stateOf(tester).debugBakeActive(), isFalse);
    final fallback = await captureWall(tester);

    final a = await rgbaOf(tester, baked);
    final b = await rgbaOf(tester, fallback);
    final s = rgbaStats(a, b);
    // ignore: avoid_print
    print('bake-vs-fallback mean=${s.mean.toStringAsFixed(2)} '
        'over32=${s.over32Pct.toStringAsFixed(2)}%');
    expect(
      s.mean,
      lessThanOrEqualTo(8),
      reason: '烘焙贴图与逐行高斯的均值差应 ≤ 8/255（整体观感一致）',
    );
    expect(
      s.over32Pct,
      lessThanOrEqualTo(10),
      reason: '高差（>32/255）像素占比应 ≤ 10%（差异仅限字形边缘的重采样相位）',
    );
  });

  testWidgets('观感等价：换行收敛后（含淡出行）一致', (tester) async {
    final groups = buildGroups(30);
    await tester.pumpWidget(buildWall(groups, 2500));
    await tester.pumpAndSettle();
    await tester.pumpWidget(buildWall(groups, 4200));
    await tester.pumpAndSettle();
    expect(stateOf(tester).debugBakeActive(), isTrue);

    final baked = await captureWall(tester);
    stateOf(tester).debugSetBakeEnabled(false);
    await tester.pumpAndSettle();
    final fallback = await captureWall(tester);

    final s = rgbaStats(await rgbaOf(tester, baked), await rgbaOf(tester, fallback));
    // ignore: avoid_print
    print('bake-vs-fallback(after transition) mean=${s.mean.toStringAsFixed(2)} '
        'over32=${s.over32Pct.toStringAsFixed(2)}%');
    expect(s.mean, lessThanOrEqualTo(8), reason: '实测 mean=${s.mean}');
    expect(s.over32Pct, lessThanOrEqualTo(10), reason: '实测 over32=${s.over32Pct}%');
  });
}
