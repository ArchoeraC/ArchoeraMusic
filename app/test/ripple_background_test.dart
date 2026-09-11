// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 水纹背景（自绘引擎）冒烟测试：加载封面后网格折射渲染无异常、可持续动画。
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/widgets/player/ripple_background.dart';

/// 生成一张 64×64 渐变 PNG 作为测试封面。
Future<String> _writeTempCover() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final paint = Paint()
    ..shader = ui.Gradient.linear(
      Offset.zero,
      const Offset(64, 64),
      const [Color(0xFFFF3B30), Color(0xFF0088FF)],
    );
  canvas.drawRect(const Rect.fromLTWH(0, 0, 64, 64), paint);
  final img = await recorder.endRecording().toImage(64, 64);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  final file = File('${Directory.systemTemp.path}/ripple_test_cover.png');
  await file.writeAsBytes(data!.buffer.asUint8List());
  return file.path;
}

Widget _wrap(Widget child) =>
    MaterialApp(home: Scaffold(body: SizedBox(width: 400, height: 300, child: child)));

void main() {
  testWidgets('有水纹封面时渲染无异常并持续动画', (tester) async {
    late final String path;
    await tester.runAsync(() async {
      path = await _writeTempCover();
      // 预热进 imageCache，使组件解析同步命中。
      final stream = FileImage(File(path)).resolve(ImageConfiguration.empty);
      final c = Completer<void>();
      stream.addListener(ImageStreamListener((_, _) => c.complete()));
      await c.future;
    });

    await tester.pumpWidget(
      _wrap(
        RippleBackground(cover: 'file://$path', playing: true, speed: 3),
      ),
    );
    // 首帧 + 图片监听回调 + 若干动画帧。
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(tester.takeException(), isNull);
    expect(find.byType(RippleBackground), findsOneWidget);
    expect(find.byType(CustomPaint), findsWidgets);
  });

  testWidgets('无封面时回退底色且无异常', (tester) async {
    await tester.pumpWidget(_wrap(const RippleBackground()));
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);
    expect(find.byType(RippleBackground), findsOneWidget);
  });

  testWidgets('性能模式（animate=false）不启动动画且无异常', (tester) async {
    late final String path;
    await tester.runAsync(() async {
      path = await _writeTempCover();
    });
    await tester.pumpWidget(
      _wrap(
        RippleBackground(cover: 'file://$path', animate: false),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('封面确实被绘制且经折射（像素非单色）', (tester) async {
    late final String path;
    await tester.runAsync(() async {
      path = await _writeTempCover();
      final stream = FileImage(File(path)).resolve(ImageConfiguration.empty);
      final c = Completer<void>();
      stream.addListener(ImageStreamListener((_, _) => c.complete()));
      await c.future;
    });

    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RepaintBoundary(
            key: key,
            child: SizedBox(
              width: 200,
              height: 200,
              child: RippleBackground(
                cover: 'file://$path',
                darken: 0,
                blurSigma: 4,
              ),
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await tester.runAsync(() => boundary.toImage());
    final bytes = await tester.runAsync(
      () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
    );
    final d = bytes!.buffer.asUint8List();
    var minR = 255, maxR = 0;
    for (var i = 0; i < d.length; i += 4) {
      final r = d[i];
      if (r < minR) minR = r;
      if (r > maxR) maxR = r;
    }
    expect(maxR - minR, greaterThan(15), reason: '封面应被绘制（红→蓝渐变）');
    expect(tester.takeException(), isNull);
  });
}
