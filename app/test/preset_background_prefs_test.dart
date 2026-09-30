// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 后台内存相关偏好读写测试（强迫症「最小化时卸载全部内存状态」+ 后台卸载页面）。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/stores/app_prefs.dart';

void main() {
  group('后台内存偏好', () {
    test('默认：后台卸载页面关、卸载全部内存状态关', () {
      final prefs = AppPrefs();
      expect(prefs.unloadBackgroundPages, isFalse);
      expect(prefs.unloadAllMemory, isFalse);
    });

    test('copyWithPower 读写后台卸载页面', () {
      final prefs = AppPrefs().copyWithPower(unloadBackgroundPages: true);
      expect(prefs.unloadBackgroundPages, isTrue);
      expect(prefs.unloadAllMemory, isFalse);
    });

    test('copyWithPreset 读写卸载全部内存状态', () {
      final prefs = AppPrefs().copyWithPreset(unloadAllMemory: true);
      expect(prefs.unloadAllMemory, isTrue);
      expect(prefs.unloadBackgroundPages, isFalse);
    });

    test('未指定字段保持原值', () {
      final base = AppPrefs()
          .copyWithPower(unloadBackgroundPages: true)
          .copyWithPreset(unloadAllMemory: true);
      final next = base.copyWithPreset(performanceMode: true);
      expect(next.unloadBackgroundPages, isTrue);
      expect(next.unloadAllMemory, isTrue);
      expect(next.performanceMode, isTrue);
    });
  });
}
