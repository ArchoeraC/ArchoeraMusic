// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:archoera_music/services/log/log.dart';

void main() {
  test('formatLine 与规范一致（时间戳 + 级别 + 标签）', () {
    final line = Log.formatLine(LogLevel.warn, 'resolver', 'x: y');
    expect(
      line,
      matches(RegExp(r'^\[\d\d:\d\d:\d\d WARN\] \[resolver\] x: y$')),
    );
  });

  test('formatLine 无标签时不带 [tag]', () {
    final line = Log.formatLine(LogLevel.info, null, 'initialize');
    expect(line, matches(RegExp(r'^\[\d\d:\d\d:\d\d INFO\] initialize$')));
  });

  test('formatLine 空标签等同无标签', () {
    final line = Log.formatLine(LogLevel.error, '', '429 too many requests');
    expect(
      line,
      matches(RegExp(r'^\[\d\d:\d\d:\d\d ERROR\] 429 too many requests$')),
    );
  });
}
