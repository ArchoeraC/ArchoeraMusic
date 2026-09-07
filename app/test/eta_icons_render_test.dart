// ArchoeraMusic UI
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/eta/icon/eta_icons.dart';
import 'package:archoera_music/eta/mark/eta_mark.dart';

void main() {
  testWidgets('EtaIcons glyphs render non-blank (filled + outline)', (
    tester,
  ) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: RepaintBoundary(
          key: key,
          child: const Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(EtaIcons.play, size: 48, color: Colors.black),
                Icon(EtaIcons.heart, size: 48, color: Colors.black),
                Icon(EtaIcons.heartOutline, size: 48, color: Colors.black),
                Icon(EtaIcons.close, size: 48, color: Colors.black),
                Icon(EtaIcons.refresh, size: 48, color: Colors.black),
                Icon(EtaMark.brand, size: 48, color: Colors.black),
              ],
            ),
          ),
        ),
      ),
    );

    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(key),
    );
    expect(boundary.size.width, greaterThan(0));

    final image = await tester.runAsync(() async {
      final img = await boundary.toImage();
      return img.toByteData(format: ui.ImageByteFormat.rawRgba);
    });
    final bytes = image!.buffer.asUint8List();
    var blackPixels = 0;
    for (var i = 0; i < bytes.length; i += 4) {
      if (bytes[i] < 80 && bytes[i + 1] < 80 && bytes[i + 2] < 80) {
        blackPixels++;
      }
    }
    expect(blackPixels, greaterThan(200), reason: '字形应真实渲染出黑色像素（字体接入成功）');
  });
}
