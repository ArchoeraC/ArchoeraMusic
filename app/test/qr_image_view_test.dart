// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 自绘二维码控件（qr 4）冒烟测试：渲染出码点、空数据安全。
library;

import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/widgets/common/qr_image_view.dart';

void main() {
  testWidgets('QrImageView 渲染出码点（含深色模块）', (tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: RepaintBoundary(
              key: key,
              child: QrImageView(
                data: 'https://example.com/login?qrcode=abcdef123456',
                size: 200,
                backgroundColor: Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);

    final boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await tester.runAsync(() => boundary.toImage());
    final bytes = await tester.runAsync(
      () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
    );
    final d = bytes!.buffer.asUint8List();
    var dark = 0, light = 0;
    for (var i = 0; i < d.length; i += 4) {
      if (d[i] < 128) {
        dark++;
      } else {
        light++;
      }
    }
    expect(dark, greaterThan(0), reason: '应存在深色码点');
    expect(light, greaterThan(0), reason: '应存在浅色背景');
  });

  testWidgets('空数据渲染空白且不抛异常', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: QrImageView(data: '', size: 100))),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byType(QrImageView), findsOneWidget);
  });
}
