// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 内嵌字体 / 图标许可正文（`assets/licenses/`）回归测试：
/// 资源随包可得、为官方原文，且满足「字体署名」弹窗的排版约定。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/licenses/bundled_font_licenses.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('内嵌许可正文随包可得且为官方原文', () async {
    final sections = await loadBundledFontLicenseSections();
    expect(sections, hasLength(bundledFontLicenses.length));

    final all = sections.map((section) => section.$2).join('\n');
    // Manrope 的 SIL OFL 1.1
    expect(all, contains('SIL OPEN FONT LICENSE'));
    expect(all, contains('Manrope Project Authors'));
    // MiSans 官方协议（中英对照）
    expect(all, contains('MiSans字体知识产权许可协议'));
    // EtaIcons 上游字形集许可
    expect(all, contains('Apache License'));
    expect(all, contains('ISC License'));
    expect(all, contains('MIT License'));

    for (final (title, body) in sections) {
      expect(title.trim(), isNotEmpty);
      expect(body.trim(), isNotEmpty, reason: '「$title」正文不应为空');
      expect(
        body.startsWith('\n\n'),
        isTrue,
        reason: '正文须以换行起始（与标题分段渲染）',
      );
    }
  });
}
