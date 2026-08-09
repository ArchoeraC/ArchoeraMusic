// 生成应用图标 PNG（品牌 Logo：圆角方块底 + 均衡器频谱条）。
//
// 运行：flutter test tool/gen_app_icon_test.dart
// 输出：linux/runner/resources/app_icon_{512,256,128,64,48,32}.png
// 与侧边栏 AppLogo 同构（方块 + graphic_eq），底色取 Material3 primary。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('generate app icon png', () async {
    const sizes = [512, 256, 128, 64, 48, 32];
    final dir = Directory('linux/runner/resources');
    dir.createSync(recursive: true);
    for (final size in sizes) {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      _paintLogo(canvas, size.toDouble());
      final image = await recorder.endRecording().toImage(size, size);
      final bytes =
          await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) continue;
      File('${dir.path}/app_icon_$size.png')
          .writeAsBytesSync(bytes.buffer.asUint8List());
    }
  });
}

/// 品牌 Logo：圆角方块底（primary #6750A4）+ 白色均衡器条（graphic_eq 形状，
/// 底部平齐，高度从中向外递减）。
void _paintLogo(ui.Canvas canvas, double size) {
  const bg = Color(0xFF6750A4);
  const fg = Color(0xFFFFFFFF);
  final rrect = RRect.fromRectAndRadius(
    Rect.fromLTWH(0, 0, size, size),
    Radius.circular(size * 0.3),
  );
  canvas.drawRRect(rrect, Paint()..color = bg);

  // graphic_eq 四根竖条高度比例（条 3 最高）
  const heights = [0.55, 0.80, 0.95, 0.70];
  final barW = size * 0.09;
  final gap = size * 0.085;
  final totalW = heights.length * barW + (heights.length - 1) * gap;
  final maxH = size * 0.44;
  final baseY = size * 0.72; // 条底基线
  final paint = Paint()
    ..color = fg
    ..style = PaintingStyle.fill;

  var x = (size - totalW) / 2;
  for (final h in heights) {
    final barH = maxH * h;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(x, baseY - barH, barW, barH),
        Radius.circular(barW / 2),
      ),
      paint,
    );
    x += barW + gap;
  }
}
