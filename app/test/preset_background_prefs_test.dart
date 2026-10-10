// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 后台内存偏好读写测试（强迫症「最小化时卸载全部内存状态」）。
///
/// 注：早期「后台卸载已访问页面」独立开关已废弃，后台 UI 子树卸载统一由本
/// 偏好（`unloadAllMemory`）驱动。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/stores/app_prefs.dart';

void main() {
  group('后台内存偏好', () {
    test('默认：卸载全部内存状态关', () {
      expect(AppPrefs().unloadAllMemory, isFalse);
    });

    test('copyWithPreset 读写卸载全部内存状态', () {
      expect(
        AppPrefs().copyWithPreset(unloadAllMemory: true).unloadAllMemory,
        isTrue,
      );
    });

    test('未指定字段保持原值', () {
      final base = AppPrefs().copyWithPreset(unloadAllMemory: true);
      final next = base.copyWithPreset(performanceMode: true);
      expect(next.unloadAllMemory, isTrue);
      expect(next.performanceMode, isTrue);
    });
  });
}
