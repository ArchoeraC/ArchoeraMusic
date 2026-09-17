// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 流体背景偏好读写测试。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/stores/app_prefs.dart';

void main() {
  group('流体背景偏好', () {
    test('默认值对齐上游（流速 4 / 比例 0.5 / 帧率 30 / 不冻结 / 不脉动）', () {
      final prefs = AppPrefs();
      expect(prefs.playerBgType, 'gradient');
      expect(prefs.playerBgFlowSpeed, 4);
      expect(prefs.playerBgRenderScale, 0.5);
      expect(prefs.playerBgFps, 30);
      expect(prefs.playerBgFreezeOnPause, isFalse);
      expect(prefs.playerBgBeat, isFalse);
    });

    test('fluid 类型被接受', () {
      final prefs = AppPrefs().copyWithPlayerBackground(type: 'fluid');
      expect(prefs.playerBgType, 'fluid');
    });

    test('copyWithPlayerBackground 读写流体参数', () {
      final prefs = AppPrefs().copyWithPlayerBackground(
        type: 'fluid',
        flowSpeed: 7.5,
        renderScale: 1.2,
        fps: 60,
        freezeOnPause: true,
        beat: true,
      );
      expect(prefs.playerBgFlowSpeed, 7.5);
      expect(prefs.playerBgRenderScale, 1.2);
      expect(prefs.playerBgFps, 60);
      expect(prefs.playerBgFreezeOnPause, isTrue);
      expect(prefs.playerBgBeat, isTrue);

      // 再写其它字段不影响流体参数。
      final next = prefs.copyWithPlayerBackground(rippleSpeed: 2);
      expect(next.playerBgFlowSpeed, 7.5);
      expect(next.playerBgBeat, isTrue);
    });

    test('流体参数越界收敛（流速 0.1~10 / 比例 0.5~2 / 帧率 24~120）', () {
      final high = AppPrefs().copyWithPlayerBackground(
        flowSpeed: 99,
        renderScale: 9,
        fps: 999,
      );
      expect(high.playerBgFlowSpeed, 10);
      expect(high.playerBgRenderScale, 2);
      expect(high.playerBgFps, 120);

      final low = AppPrefs().copyWithPlayerBackground(
        flowSpeed: -3,
        renderScale: 0.01,
        fps: 1,
      );
      expect(low.playerBgFlowSpeed, 0.1);
      expect(low.playerBgRenderScale, 0.5);
      expect(low.playerBgFps, 24);
    });
  });
}
