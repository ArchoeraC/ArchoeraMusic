// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// [BakedImageBackground] 冒烟测试：测试（软渲染）环境下走实时滤镜回退，
/// 构建/参数变更不抛异常。
library;

import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/widgets/common/baked_image_background.dart';

/// 1x1 透明 PNG（避免引入额外测试依赖）。
final Uint8List _transparentPng = Uint8List.fromList(<int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

Widget _wrap({double blur = 12, double scale = 1.2, double dim = 0.4}) =>
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 320,
          height: 180,
          child: BakedImageBackground(
            provider: MemoryImage(_transparentPng),
            blurSigma: blur,
            scale: scale,
            dim: dim,
          ),
        ),
      ),
    );

void main() {
  testWidgets('软渲染回退渲染无异常', (tester) async {
    await tester.pumpWidget(_wrap());
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byType(BakedImageBackground), findsOneWidget);
  });

  testWidgets('参数变更（模糊/缩放/压暗）不抛异常', (tester) async {
    await tester.pumpWidget(_wrap());
    await tester.pump();
    await tester.pumpWidget(_wrap(blur: 0, scale: 1.0, dim: 0.6));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
