// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// LyricsParagraphCache 单测：键复用 / 翻译槽 / 可见窗口 prune / clear。
library;

import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/widgets/player/lyrics_v7/lyrics_paragraph_cache.dart';

ui.Paragraph _build(String text, double width) {
  final b = ui.ParagraphBuilder(ui.ParagraphStyle(fontSize: 14))
    ..pushStyle(ui.TextStyle(color: const ui.Color(0xFF000000), fontSize: 14))
    ..addText(text)
    ..pop();
  final p = b.build();
  p.layout(ui.ParagraphConstraints(width: width));
  return p;
}

void main() {
  test('同键复用、异键重建', () {
    final c = LyricsParagraphCache();
    final p1 = c.obtainMain(0, 'k', () => _build('a', 100));
    final p2 = c.obtainMain(0, 'k', () => _build('b', 100));
    expect(identical(p1, p2), isTrue, reason: '同键应复用同一段落对象');
    final p3 = c.obtainMain(0, 'k2', () => _build('c', 100));
    expect(identical(p1, p3), isFalse, reason: '异键应重建');
    expect(c.entryCount, 1);
  });

  test('翻译槽：null 键清空并返回 null', () {
    final c = LyricsParagraphCache();
    final t = c.obtainTranslation(0, 't', () => _build('译', 100));
    expect(t, isNotNull);
    final t2 = c.obtainTranslation(0, null, () => _build('x', 100));
    expect(t2, isNull);
    final t3 = c.obtainTranslation(0, null, () => _build('x', 100));
    expect(t3, isNull, reason: 'null 键稳定返回 null');
    expect(c.entryCount, 1);
  });

  test('pruneTo 只保留可见行（内存有界）', () {
    final c = LyricsParagraphCache();
    for (var i = 0; i < 100; i++) {
      c.obtainMain(i, 'k', () => _build('$i', 100));
    }
    expect(c.entryCount, 100);
    c.pruneTo({10, 11, 12});
    expect(c.entryCount, 3);
  });

  test('clear 清空全部', () {
    final c = LyricsParagraphCache();
    c.obtainMain(0, 'k', () => _build('a', 100));
    c.obtainTranslation(0, 't', () => _build('b', 100));
    c.clear();
    expect(c.entryCount, 0);
  });
}
