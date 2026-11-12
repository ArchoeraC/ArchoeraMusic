// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 图片背景亮度采样与「可读性遮罩下限」单测（移植自 ArchoeraCX
/// `render/image_luminance`）：纯函数边界 + 真实 PNG 解码。
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/render/image_luminance.dart';
import 'package:archoera_music/theme/app_theme.dart';

/// 写一张纯色 32×32 PNG，让采样结果可预期。
Future<Uint8List> _solidPng(int argb) async {
  final recorder = ui.PictureRecorder();
  Canvas(
    recorder,
  ).drawRect(const Rect.fromLTWH(0, 0, 32, 32), Paint()..color = Color(argb));
  final picture = recorder.endRecording();
  final image = await picture.toImage(32, 32);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  } finally {
    picture.dispose();
    image.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('backgroundDimFloorFor', () {
    test('未采样与暗图保持默认下限', () {
      expect(backgroundDimFloorFor(null), kBackgroundDimMin);
      expect(backgroundDimFloorFor(0.02), kBackgroundDimMin);
      // 18% 灰已经满足对比度预算，不需要额外加深。
      expect(backgroundDimFloorFor(0.2), kBackgroundDimMin);
    });

    test('亮图抬起下限以保证正文可读', () {
      // 纯白约需 58% 黑遮罩，才能让 #ECECEC 正文达到 4.5:1。
      final white = backgroundDimFloorFor(1);
      expect(white, closeTo(0.58, 0.01));
      expect(white, greaterThan(backgroundDimFloorFor(0.6)));
      expect(
        backgroundDimFloorFor(0.6),
        greaterThanOrEqualTo(kBackgroundDimMin),
      );
    });

    test('下限不会把背景图吃掉', () {
      expect(
        backgroundDimFloorFor(1),
        lessThanOrEqualTo(kBackgroundDimAutoMax),
      );
      expect(backgroundDimFloorFor(1), lessThan(kBackgroundDimMax));
    });

    test('对比度预算锚定图片模式的正文色', () {
      // 图片模式强制暗色主题，正文恒为暗色板 onSurface；调色板若改动，
      // 这里会先失败，提醒同步 image_luminance.dart 的 _imageModeTextArgb。
      expect(AppPalette.dark.onSurface.toARGB32(), 0xFFECECEC);
    });
  });

  group('sampleImageLuminance', () {
    testWidgets('只统计不透明像素，读不到的文件返回 null', (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'archoera-luminance',
      );
      addTearDown(() => directory.deleteSync(recursive: true));

      await tester.runAsync(() async {
        final white = File('${directory.path}/white.png')
          ..writeAsBytesSync(await _solidPng(0xFFFFFFFF));
        final black = File('${directory.path}/black.png')
          ..writeAsBytesSync(await _solidPng(0xFF000000));
        final clear = File('${directory.path}/clear.png')
          ..writeAsBytesSync(await _solidPng(0x00000000));

        expect(await sampleImageLuminance(white.path), closeTo(1, 0.02));
        expect(await sampleImageLuminance(black.path), closeTo(0, 0.02));
        // 全透明（或文件缺失）没有可用信息：保留用户自己的遮罩。
        expect(await sampleImageLuminance(clear.path), isNull);
        expect(
          await sampleImageLuminance('${directory.path}/missing.png'),
          isNull,
        );
      });
    });
  });
}
