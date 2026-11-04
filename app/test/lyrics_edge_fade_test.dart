// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 歌词上下渐隐的两种实现回归：
///
/// - `lyricsEdgeFadeAt` 与 `LyricsEdgeFade` 的渐变停点严格一致（纯函数）；
/// - 环境变量 `ARCHOERA_LYRICS_FADE` 的解析；
/// - 物理墙逐行渐隐（零离屏层）确实把上下边缘的行画淡了，且不抛异常。
library;

import 'dart:ui' as ui;

import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:archoera_music/services/lyrics/lyric_line.dart';
import 'package:archoera_music/widgets/player/lyrics_edge_fade.dart';
import 'package:archoera_music/widgets/player/lyrics_v7/lyrics_physics_wall.dart';

const _boundaryKey = ValueKey('edge_fade_boundary');

List<LyricGroup> buildGroups(int count) => [
  for (var i = 0; i < count; i++)
    LyricGroup(
      original: LyricLine(timeMs: i * 1000, text: '第 $i 行'),
      endMs: (i + 1) * 1000,
    ),
];

Widget buildWall(List<LyricGroup> groups, int pos, {required bool edgeFade}) =>
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 500,
          child: RepaintBoundary(
            key: _boundaryKey,
            child: AmllPhysicsWall(
              groups: groups,
              positionMs: pos,
              onSeek: (_) {},
              playing: false,
              edgeFade: edgeFade,
            ),
          ),
        ),
      ),
    );

/// 旧实现：外层 `ShaderMask`（`LyricsEdgeFade`）。
Widget buildShaderFadeWall(List<LyricGroup> groups, int pos) => MaterialApp(
  home: Scaffold(
    body: SizedBox(
      width: 400,
      height: 500,
      child: RepaintBoundary(
        key: _boundaryKey,
        child: LyricsEdgeFade(
          child: AmllPhysicsWall(
            groups: groups,
            positionMs: pos,
            onSeek: (_) {},
            playing: false,
          ),
        ),
      ),
    ),
  ),
);

Future<List<int>> captureRgba(WidgetTester tester) async {
  final boundary =
      tester.renderObject(find.byKey(_boundaryKey)) as RenderRepaintBoundary;
  final img = await tester.runAsync(() => boundary.toImage());
  if (img == null) fail('截图失败（runAsync 返回 null）');
  final data = await tester.runAsync(
    () => img.toByteData(format: ui.ImageByteFormat.rawRgba),
  );
  if (data == null) fail('toByteData 失败（runAsync 返回 null）');
  return data.buffer.asUint8List();
}

void main() {
  group('lyricsEdgeFadeAt', () {
    test('停点与 LyricsEdgeFade 的渐变一致', () {
      // stops [0, .05, .10, .75, .85, 1.0] / alphas [0, .6, 1, 1, .6, 0]
      expect(lyricsEdgeFadeAt(0), closeTo(0.0, 1e-9));
      expect(lyricsEdgeFadeAt(0.05), closeTo(0.6, 1e-9));
      expect(lyricsEdgeFadeAt(0.10), closeTo(1.0, 1e-9));
      expect(lyricsEdgeFadeAt(0.40), closeTo(1.0, 1e-9));
      expect(lyricsEdgeFadeAt(0.75), closeTo(1.0, 1e-9));
      expect(lyricsEdgeFadeAt(0.85), closeTo(0.6, 1e-9));
      expect(lyricsEdgeFadeAt(1.0), closeTo(0.0, 1e-9));
    });

    test('越界夹紧，中段单调', () {
      expect(lyricsEdgeFadeAt(-1), 0.0);
      expect(lyricsEdgeFadeAt(2), 0.0);
      var prev = -1.0;
      for (var t = 0.0; t <= 0.1001; t += 0.01) {
        final v = lyricsEdgeFadeAt(t);
        expect(v, greaterThanOrEqualTo(prev - 1e-9));
        prev = v;
      }
      prev = 1.1;
      for (var t = 0.85; t <= 1.0001; t += 0.01) {
        final v = lyricsEdgeFadeAt(t);
        expect(v, lessThanOrEqualTo(prev + 1e-9));
        prev = v;
      }
    });

    test('环境变量解析', () {
      // 默认 = 逐行 alpha（零离屏层）；`shader` 是显式回退。
      expect(lyricsEdgeFadeModeFrom(null), LyricsEdgeFadeMode.wall);
      expect(lyricsEdgeFadeModeFrom(''), LyricsEdgeFadeMode.wall);
      expect(lyricsEdgeFadeModeFrom('shader'), LyricsEdgeFadeMode.shader);
      expect(lyricsEdgeFadeModeFrom('mask'), LyricsEdgeFadeMode.shader);
      expect(lyricsEdgeFadeModeFrom('wall'), LyricsEdgeFadeMode.wall);
      expect(lyricsEdgeFadeModeFrom(' WALL '), LyricsEdgeFadeMode.wall);
      expect(lyricsEdgeFadeModeFrom('perline'), LyricsEdgeFadeMode.wall);
      expect(lyricsEdgeFadeModeFrom('off'), LyricsEdgeFadeMode.off);
      expect(lyricsEdgeFadeModeFrom('none'), LyricsEdgeFadeMode.off);
      expect(lyricsEdgeFadeModeFrom('0'), LyricsEdgeFadeMode.off);
      expect(lyricsEdgeFadeModeFrom('whatever'), LyricsEdgeFadeMode.wall);
      expect(defaultLyricsEdgeFadeMode, LyricsEdgeFadeMode.wall);
    });

    test('生效实现：设置页偏好生效，环境变量可覆盖', () {
      final env = lyricsEdgeFadeEnvOverride;
      // 未设环境变量（常规测试/正常启动）时按设置值；设了则以环境变量为准。
      expect(
        resolveLyricsEdgeFadeMode('shader'),
        env ?? LyricsEdgeFadeMode.shader,
      );
      expect(resolveLyricsEdgeFadeMode('off'), env ?? LyricsEdgeFadeMode.off);
      expect(resolveLyricsEdgeFadeMode(null), env ?? LyricsEdgeFadeMode.wall);
      expect(
        resolveLyricsEdgeFadeMode('bogus'),
        env ?? LyricsEdgeFadeMode.wall,
      );
    });
  });

  testWidgets('逐行渐隐把上下边缘行画淡（零离屏层实现有效）', (tester) async {
    final groups = buildGroups(20);

    await tester.pumpWidget(buildWall(groups, 10000, edgeFade: false));
    await tester.pumpAndSettle();
    final plain = await captureRgba(tester);

    await tester.pumpWidget(buildWall(groups, 10000, edgeFade: true));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final faded = await captureRgba(tester);

    expect(faded.length, plain.length);
    var sum = 0;
    var maxD = 0;
    var changed = 0;
    for (var i = 0; i < plain.length; i++) {
      final d = (plain[i] - faded[i]).abs();
      sum += d;
      if (d > maxD) maxD = d;
      if (d > 8) changed++;
    }
    final mean = sum / plain.length;
    // ignore: avoid_print
    print(
      'edge-fade pixel diff mean=${mean.toStringAsFixed(2)} '
      'max=$maxD changedPx=$changed',
    );
    expect(maxD, greaterThan(16), reason: '逐行渐隐应明显改变上下边缘行的透明度');
    expect(changed, greaterThan(0));
  });

  testWidgets('观感对比：逐行渐隐 vs ShaderMask（差异只在上下边缘带）', (tester) async {
    final groups = buildGroups(20);

    await tester.pumpWidget(buildShaderFadeWall(groups, 10000));
    await tester.pumpAndSettle();
    final shader = await captureRgba(tester);

    await tester.pumpWidget(buildWall(groups, 10000, edgeFade: true));
    await tester.pumpAndSettle();
    final wall = await captureRgba(tester);

    var sum = 0;
    var over32 = 0;
    var maxD = 0;
    final n = shader.length ~/ 4;
    for (var i = 0; i < shader.length; i += 4) {
      var d = 0;
      for (var c = 0; c < 4; c++) {
        final v = (shader[i + c] - wall[i + c]).abs();
        if (v > d) d = v;
      }
      sum += d;
      if (d > 32) over32++;
      if (d > maxD) maxD = d;
    }
    final mean = sum / n;
    final pct = over32 * 100 / n;
    // ignore: avoid_print
    print(
      'wall-vs-shader mean=${mean.toStringAsFixed(2)} '
      'over32=${pct.toStringAsFixed(2)}% max=$maxD',
    );
    // 只要求「不是整体变暗/变亮」：逐行模式是阶梯式，边缘带必然有差，
    // 但全画面平均差应远小于「少画一半文字」那种量级。
    expect(mean, lessThanOrEqualTo(6), reason: '实测 mean=$mean');
    expect(pct, lessThanOrEqualTo(12), reason: '实测 over32=$pct%');
  });

  testWidgets('渐隐曲线中段（激活行附近）不受影响', (tester) async {
    final groups = buildGroups(20);
    await tester.pumpWidget(buildWall(groups, 10000, edgeFade: false));
    await tester.pumpAndSettle();
    final plain = await captureRgba(tester);
    await tester.pumpWidget(buildWall(groups, 10000, edgeFade: true));
    await tester.pumpAndSettle();
    final faded = await captureRgba(tester);

    // 视口高 500：中心 40%~60% 落在曲线 100% 区间，应逐像素一致。
    const w = 400;
    const h = 500;
    final fromRow = (h * 0.40).round();
    final toRow = (h * 0.60).round();
    var maxD = 0;
    for (var y = fromRow; y < toRow; y++) {
      for (var x = 0; x < w; x++) {
        final i = (y * w + x) * 4;
        for (var c = 0; c < 4; c++) {
          final d = (plain[i + c] - faded[i + c]).abs();
          if (d > maxD) maxD = d;
        }
      }
    }
    expect(maxD, lessThanOrEqualTo(2), reason: '中段渐隐值恒为 1，实测差 $maxD');
  });
}
