// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 歌词偏好测试：高亮跟随全局主题色开关。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/stores/app_prefs.dart';

void main() {
  group('lyricFollowAccent', () {
    test('默认关闭', () {
      expect(AppPrefs().lyricFollowAccent, isFalse);
    });

    test('可开启且不影响手调高亮色的存储', () {
      final base = AppPrefs().copyWithLyricStyle(playedColor: 0xFF112233);
      expect(base.lyricPlayedColor, 0xFF112233);

      final on = base.copyWithLyricStyle(followAccent: true);
      expect(on.lyricFollowAccent, isTrue);
      // 手动颜色仍保留，关闭开关后即可恢复。
      expect(on.lyricPlayedColor, 0xFF112233);

      final off = on.copyWithLyricStyle(followAccent: false);
      expect(off.lyricFollowAccent, isFalse);
    });
  });
}
