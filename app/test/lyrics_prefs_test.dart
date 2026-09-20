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

  group('amllBlurQuality（失焦档位）', () {
    test('默认 auto（自动，带帧预算兜底）', () {
      expect(AppPrefs().amllBlurQuality, 'auto');
    });

    test('四个档位都能写入并读回', () {
      for (final q in amllBlurQualities) {
        expect(AppPrefs().copyWithAmll(blurQuality: q).amllBlurQuality, q);
      }
    });

    test('非法/未知值回落到 auto，不写入脏值', () {
      expect(
        AppPrefs(initialData: {amllBlurQualityKey: 'bogus'}).amllBlurQuality,
        'auto',
      );
      expect(
        AppPrefs().copyWithAmll(blurQuality: 'bogus').amllBlurQuality,
        'auto',
      );
    });

    test('旧键 amll.enableBlur=false 迁移为 off；新键优先', () {
      expect(
        AppPrefs(initialData: {amllEnableBlurKey: false}).amllBlurQuality,
        'off',
      );
      expect(
        AppPrefs(initialData: {amllEnableBlurKey: true}).amllBlurQuality,
        'auto',
      );
      // 新键存在时忽略旧键（老用户改过设置也不受影响）。
      expect(
        AppPrefs(
          initialData: {
            amllEnableBlurKey: false,
            amllBlurQualityKey: 'quality',
          },
        ).amllBlurQuality,
        'quality',
      );
    });
  });
}
