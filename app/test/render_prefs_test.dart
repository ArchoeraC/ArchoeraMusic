// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 「性能 / 渲染」偏好读写测试（水纹着色器 / 动态层降分辨率 / 损伤区裁剪）。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/stores/app_prefs.dart';

void main() {
  group('性能 / 渲染偏好', () {
    test('默认值：着色器开、降分辨率关、损伤区裁剪关', () {
      final prefs = AppPrefs();
      expect(prefs.rippleShaderEnabled, defaultRippleShader);
      expect(prefs.rippleShaderEnabled, isTrue);
      expect(prefs.rippleLowRes, isFalse);
      expect(prefs.rippleDamageClip, isFalse);
    });

    test('copyWithRippleRender 读写三个开关', () {
      final prefs = AppPrefs().copyWithRippleRender(
        shader: false,
        lowRes: true,
        damageClip: true,
      );
      expect(prefs.rippleShaderEnabled, isFalse);
      expect(prefs.rippleLowRes, isTrue);
      expect(prefs.rippleDamageClip, isTrue);
    });

    test('未指定字段保持原值', () {
      final base = AppPrefs().copyWithRippleRender(lowRes: true);
      final next = base.copyWithRippleRender(shader: false);
      expect(next.rippleShaderEnabled, isFalse);
      expect(next.rippleLowRes, isTrue);
      expect(next.rippleDamageClip, isFalse);
    });
  });
}
