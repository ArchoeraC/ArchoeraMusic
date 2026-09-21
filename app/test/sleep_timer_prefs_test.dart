// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 睡眠定时偏好回归测试：预设的归一化（去重/夹取/删光）、
/// 键缺失回退默认、自定义分钟数的合法性。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/stores/app_prefs.dart';

void main() {
  group('sleepTimerPresets', () {
    test('键缺失回退默认 15/30/60/90', () {
      expect(AppPrefs().sleepTimerPresets, defaultSleepTimerPresets);
    });

    test('去重、夹取到 1~600、忽略非法项', () {
      final p = AppPrefs(
        initialData: {
          sleepTimerPresetsKey: [30, 30, 0, 999, 'x', 45.6, 600, 1],
        },
      );
      // 0→1、999→600、45.6→46、'x' 忽略、30 去重。
      expect(p.sleepTimerPresets, [30, 1, 600, 46]);
    });

    test('空列表是合法状态（用户删光预设，不回退默认）', () {
      final p = AppPrefs(initialData: {sleepTimerPresetsKey: const <int>[]});
      expect(p.sleepTimerPresets, isEmpty);
    });

    test('copyWith 往返保留列表', () {
      final p = AppPrefs().copyWithSleepTimerPresets([5, 10, 20]);
      expect(p.sleepTimerPresets, [5, 10, 20]);
    });
  });

  group('sleepTimerCustomMinutes', () {
    test('未设置返回 null', () {
      expect(AppPrefs().sleepTimerCustomMinutes, isNull);
    });

    test('合法值返回，超范围返回 null', () {
      expect(
        AppPrefs(
          initialData: {sleepTimerCustomMinutesKey: 25},
        ).sleepTimerCustomMinutes,
        25,
      );
      expect(
        AppPrefs(
          initialData: {sleepTimerCustomMinutesKey: 0},
        ).sleepTimerCustomMinutes,
        isNull,
      );
      expect(
        AppPrefs(
          initialData: {sleepTimerCustomMinutesKey: 999},
        ).sleepTimerCustomMinutes,
        isNull,
      );
    });

    test('copyWith 夹取到 1~600', () {
      expect(
        AppPrefs().copyWithSleepTimerCustomMinutes(0).sleepTimerCustomMinutes,
        1,
      );
      expect(
        AppPrefs().copyWithSleepTimerCustomMinutes(999).sleepTimerCustomMinutes,
        600,
      );
    });
  });
}
