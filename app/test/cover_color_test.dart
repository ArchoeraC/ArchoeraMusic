// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 封面主色提取回归：浅色背景不再高频失败、复杂封面能出代表色、单调封面回退。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_color_utilities/material_color_utilities.dart';

import 'package:archoera_music/theme/cover_color.dart';

/// 生成 64×64 封面 PNG（[argbAt] 返回 0xAARRGGBB）。
Future<String> _writeCover(int Function(int x, int y) argbAt) async {
  const n = 64;
  final bytes = Uint8List(n * n * 4);
  for (var y = 0; y < n; y++) {
    for (var x = 0; x < n; x++) {
      final argb = argbAt(x, y);
      final i = (y * n + x) * 4;
      bytes[i] = (argb >> 16) & 0xFF;
      bytes[i + 1] = (argb >> 8) & 0xFF;
      bytes[i + 2] = argb & 0xFF;
      bytes[i + 3] = (argb >> 24) & 0xFF;
    }
  }
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    bytes,
    n,
    n,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  final img = await completer.future;
  final png = await img.toByteData(format: ui.ImageByteFormat.png);
  final f = File(
    '${Directory.systemTemp.path}/cover_test_${DateTime.now().microsecondsSinceEpoch}.png',
  );
  await f.writeAsBytes(png!.buffer.asUint8List());
  return f.path;
}

void main() {
  testWidgets('浅色背景封面仍能提取到主体色', (tester) async {
    late final String path;
    await tester.runAsync(() async {
      // 近白底 + 中央饱和蓝主体（浅色封面此前易判失败）。
      path = await _writeCover(
        (x, y) => (x > 20 && x < 44 && y > 20 && y < 44)
            ? 0xFF1E63FF
            : 0xFFF5F5F5,
      );
    });
    final color = await tester.runAsync(
      () => extractDominantColor('file://$path'),
    );
    expect(color, isNotNull, reason: '浅色封面不应失败');
    final hct = Hct.fromInt(color!.toARGB32());
    expect(hct.hue, inInclusiveRange(200, 280), reason: '应取到主体蓝色相');
    expect(hct.tone, inInclusiveRange(28, 72), reason: '基色色调应受约束');
  });

  testWidgets('复杂多彩封面能提取代表色', (tester) async {
    late final String path;
    await tester.runAsync(() async {
      path = await _writeCover((x, y) {
        if (x < 21) return 0xFFE53935; // 红
        if (x < 42) return 0xFF43A047; // 绿
        return 0xFF1E88E5; // 蓝
      });
    });
    final color = await tester.runAsync(
      () => extractDominantColor('file://$path'),
    );
    expect(color, isNotNull, reason: '复杂封面应能出代表色');
    expect(color!.toARGB32() & 0xFFFFFF, isNot(0), reason: '非黑');
  });

  testWidgets('单调灰封面保持近中性（不再判无效）', (tester) async {
    late final String path;
    await tester.runAsync(() async {
      path = await _writeCover((x, y) => 0xFF808080);
    });
    final color = await tester.runAsync(
      () => extractDominantColor('file://$path'),
    );
    expect(color, isNotNull, reason: '纯灰封面也应出基色（近中性），不判无效');
    final hct = Hct.fromInt(color!.toARGB32());
    expect(hct.chroma, lessThan(2), reason: '纯灰保持近中性');
    expect(hct.tone, inInclusiveRange(28, 72));
  });

  testWidgets('偏色灰封面采用其色相（低色度门槛 _minChroma=2）', (tester) async {
    late final String path;
    await tester.runAsync(() async {
      path = await _writeCover((x, y) => 0xFF807C88); // 略偏紫的灰
    });
    final color = await tester.runAsync(
      () => extractDominantColor('file://$path'),
    );
    expect(color, isNotNull);
    final hct = Hct.fromInt(color!.toARGB32());
    expect(hct.chroma, greaterThanOrEqualTo(2), reason: '偏色灰应保留色相并抬到可用色度');
    expect(hct.tone, inInclusiveRange(28, 72));
  });
}
