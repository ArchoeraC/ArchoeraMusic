// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 图片背景「可读性遮罩下限」的偏好语义：用户意图（存盘 dim）与生效值分离，
/// 亮图只抬高下限、不改写用户设置；换图期间保留旧下限避免闪动。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/render/image_luminance.dart';
import 'package:archoera_music/stores/app_prefs.dart';

void main() {
  group('图片背景遮罩下限', () {
    test('未测量时沿用用户设置', () {
      final prefs = AppPrefs();
      expect(prefs.backgroundDimFloor, kBackgroundDimMin);
      expect(prefs.effectiveBackgroundDim, closeTo(0.4, 1e-9));
    });

    test('亮图抬高生效遮罩，但不改写用户意图', () {
      final prefs = AppPrefs(
        initialData: {
          backgroundImageKey: '/tmp/bright.png',
          backgroundLuminanceKey: 1.0,
        },
      );
      expect(prefs.backgroundDim, closeTo(0.4, 1e-9));
      expect(prefs.backgroundDimFloor, closeTo(0.58, 0.01));
      expect(prefs.effectiveBackgroundDim, closeTo(0.58, 0.01));
    });

    test('用户设置高于下限时保持用户值', () {
      final prefs = AppPrefs(
        initialData: {
          backgroundImageKey: '/tmp/bright.png',
          backgroundLuminanceKey: 1.0,
          backgroundDimKey: 0.8,
        },
      );
      expect(prefs.effectiveBackgroundDim, closeTo(0.8, 1e-9));
    });

    test('滑块值低于下限时收敛到下限', () {
      final prefs = AppPrefs(
        initialData: {
          backgroundImageKey: '/tmp/bright.png',
          backgroundLuminanceKey: 1.0,
        },
      );
      final lowered = prefs.copyWithBackground(dim: 0.2);
      expect(lowered.backgroundDim, closeTo(prefs.backgroundDimFloor, 1e-9));
    });

    test('换图保留旧下限直到新采样到达（避免遮罩闪动）', () {
      final prefs = AppPrefs(
        initialData: {
          backgroundImageKey: '/tmp/bright.png',
          backgroundLuminanceKey: 1.0,
        },
      );
      final switched = prefs.copyWithBackground(image: '/tmp/dark.png');
      expect(switched.backgroundImage, '/tmp/dark.png');
      expect(switched.backgroundLuminance, 1.0);
      expect(switched.backgroundDimFloor, closeTo(0.58, 0.01));
    });

    test('采样结果可清空，亮度值收敛到 0~1', () {
      final bright = AppPrefs(
        initialData: {
          backgroundImageKey: '/tmp/bright.png',
          backgroundLuminanceKey: 1.0,
        },
      );
      final cleared = bright.copyWithBackground(clearLuminance: true);
      expect(cleared.backgroundLuminance, isNull);
      expect(cleared.backgroundDimFloor, kBackgroundDimMin);

      final overRange = AppPrefs(initialData: {backgroundLuminanceKey: 1.4});
      expect(overRange.backgroundLuminance, 1.0);
    });

    test('清除背景图同时清掉亮度缓存', () {
      final prefs = AppPrefs(
        initialData: {
          backgroundImageKey: '/tmp/bright.png',
          backgroundLuminanceKey: 1.0,
        },
      );
      final cleared = prefs.copyWithBackground(clearImage: true);
      expect(cleared.backgroundImage, isNull);
      expect(cleared.backgroundLuminance, isNull);
      expect(cleared.effectiveBackgroundDim, cleared.backgroundDim);
    });
  });
}
