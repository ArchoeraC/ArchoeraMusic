// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 流体背景冒烟测试：无着色器/测试环境下构建与动画生命周期无异常
/// （预烘焙与位移图在 FLUTTER_TEST 下按设计跳过，单独由纯函数测试覆盖）。
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/widgets/player/background/fluid_background.dart';

Future<String> _writeTempCover() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final paint = Paint()
    ..shader = ui.Gradient.linear(Offset.zero, const Offset(64, 64), const [
      Color(0xFFFF3B30),
      Color(0xFF0088FF),
    ]);
  canvas.drawRect(const Rect.fromLTWH(0, 0, 64, 64), paint);
  final img = await recorder.endRecording().toImage(64, 64);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  final file = File('${Directory.systemTemp.path}/fluid_test_cover.png');
  await file.writeAsBytes(data!.buffer.asUint8List());
  return file.path;
}

Widget _wrap(Widget child) => ProviderScope(
  child: MaterialApp(
    home: Scaffold(body: SizedBox(width: 400, height: 300, child: child)),
  ),
);

void main() {
  testWidgets('无封面时构建且无异常', (tester) async {
    await tester.pumpWidget(_wrap(const FluidBackground()));
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);
    expect(find.byType(FluidBackground), findsOneWidget);
  });

  testWidgets('有封面持续动画无异常', (tester) async {
    late final String path;
    await tester.runAsync(() async {
      path = await _writeTempCover();
      final stream = FileImage(File(path)).resolve(ImageConfiguration.empty);
      final c = Completer<void>();
      stream.addListener(ImageStreamListener((_, _) => c.complete()));
      await c.future;
    });

    await tester.pumpWidget(
      _wrap(FluidBackground(cover: 'file://$path', flowSpeed: 4)),
    );
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(tester.takeException(), isNull);
    expect(find.byType(FluidBackground), findsOneWidget);
    expect(find.byType(CustomPaint), findsWidgets);
  });

  testWidgets('性能模式（animate=false）不启动动画且无异常', (tester) async {
    late final String path;
    await tester.runAsync(() async {
      path = await _writeTempCover();
    });
    await tester.pumpWidget(
      _wrap(FluidBackground(cover: 'file://$path', animate: false)),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('renderScale 离屏路径（测试环境回退直绘）无异常', (tester) async {
    late final String path;
    await tester.runAsync(() async {
      path = await _writeTempCover();
      final stream = FileImage(File(path)).resolve(ImageConfiguration.empty);
      final c = Completer<void>();
      stream.addListener(ImageStreamListener((_, _) => c.complete()));
      await c.future;
    });

    await tester.pumpWidget(
      _wrap(FluidBackground(cover: 'file://$path', renderScale: 0.5)),
    );
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(tester.takeException(), isNull);
  });
}
