// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 播放页背景偏好读写测试。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/stores/app_prefs.dart';

void main() {
  group('播放页背景偏好', () {
    test('默认渐变、速度 3', () {
      final prefs = AppPrefs();
      expect(prefs.playerBgType, defaultPlayerBgType);
      expect(prefs.playerBgType, 'gradient');
      expect(prefs.playerBgRippleSpeed, defaultPlayerBgRippleSpeed);
    });

    test('copyWithPlayerBackground 读写', () {
      final prefs = AppPrefs().copyWithPlayerBackground(
        type: 'solid',
        rippleSpeed: 5,
      );
      expect(prefs.playerBgType, 'solid');
      expect(prefs.playerBgRippleSpeed, 5);
    });

    test('非法类型不写入（回退默认）、速度收敛到 1~6', () {
      final prefs = AppPrefs().copyWithPlayerBackground(
        type: 'bogus',
        rippleSpeed: 99,
      );
      expect(prefs.playerBgType, 'gradient');
      expect(prefs.playerBgRippleSpeed, 6);

      final low = AppPrefs().copyWithPlayerBackground(rippleSpeed: -3);
      expect(low.playerBgRippleSpeed, 1);
    });
  });
}
