// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// [BlurredCover] 冒烟测试：测试（软渲染）环境下走实时滤镜回退，
/// 构建 / 封面变更（交叉淡入）不抛异常。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/widgets/player/background/blurred_cover.dart';

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

Widget _wrap(String cover) => MaterialApp(
  home: Scaffold(
    body: SizedBox(
      width: 320,
      height: 180,
      child: BlurredCover(cover: cover),
    ),
  ),
);

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('blur-cover'));
  tearDown(() => dir.deleteSync(recursive: true));

  testWidgets('软渲染回退渲染无异常', (tester) async {
    final f = File('${dir.path}/a.png')..writeAsBytesSync(_transparentPng);
    await tester.pumpWidget(_wrap(f.path));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byType(BlurredCover), findsOneWidget);
  });

  testWidgets('封面变更（交叉淡入）无异常', (tester) async {
    final a = File('${dir.path}/a.png')..writeAsBytesSync(_transparentPng);
    final b = File('${dir.path}/b.png')..writeAsBytesSync(_transparentPng);
    await tester.pumpWidget(_wrap(a.path));
    await tester.pump();
    await tester.pumpWidget(_wrap(b.path));
    await tester.pump(const Duration(milliseconds: 120));
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);
  });
}
