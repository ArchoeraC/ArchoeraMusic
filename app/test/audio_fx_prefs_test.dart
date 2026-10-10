// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 音频效果偏好：变调（pitch）与响度归一化（ReplayGain 口径 / 兜底增益）。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/stores/app_prefs.dart';

void main() {
  group('变调偏好', () {
    test('默认原调（0 半音）', () {
      expect(AppPrefs().pitchSemitones, 0.0);
    });

    test('copyWithPitch 读写并夹取到 [-12, 12]', () {
      expect(AppPrefs().copyWithPitch(3.5).pitchSemitones, 3.5);
      expect(AppPrefs().copyWithPitch(-8).pitchSemitones, -8.0);
      expect(AppPrefs().copyWithPitch(99).pitchSemitones, pitchMaxSemitones);
      expect(AppPrefs().copyWithPitch(-99).pitchSemitones, pitchMinSemitones);
    });
  });

  group('响度归一化偏好', () {
    test('默认关闭 / track 口径', () {
      final prefs = AppPrefs();
      expect(prefs.normalizationEnabled, isFalse);
      expect(prefs.normalizationAlbum, isFalse);
    });

    test('copyWithNormalization 写开关与 album 口径', () {
      final prefs = AppPrefs().copyWithNormalization(true, album: true);
      expect(prefs.normalizationEnabled, isTrue);
      expect(prefs.normalizationAlbum, isTrue);
      // 仅改开关时 album 保持原值。
      expect(prefs.copyWithNormalization(false).normalizationAlbum, isTrue);
    });
  });

  group('归一化兜底增益', () {
    test('无分析结果 / 非有限值 → 0', () {
      expect(normalizationGainDb(), 0.0);
      expect(normalizationGainDb(lufs: double.nan), 0.0);
      expect(normalizationGainDb(lufs: double.infinity), 0.0);
    });

    test('达到目标响度 → 0；低于目标 → 正增益', () {
      expect(normalizationGainDb(lufs: normalizationTargetLufs), 0.0);
      expect(normalizationGainDb(lufs: -23), 5.0);
      expect(normalizationGainDb(lufs: -13), -5.0);
    });

    test('峰值削波保护：峰值 0.5 → 增益不超过 +6.02dB', () {
      // 目标 -18、曲目 -30 名义增益 +12；峰值 0.5 限制到 ~+6.02dB。
      final gain = normalizationGainDb(lufs: -30, peak: 0.5);
      expect(gain, closeTo(6.0206, 1e-3));
    });

    test('峰值有余量时名义增益不被限制', () {
      // 峰值 0.2 → 峰限 ~+13.98dB，名义 +5dB 生效。
      expect(normalizationGainDb(lufs: -23, peak: 0.2), 5.0);
    });

    test('峰值满刻度：任何正增益都被限制为 0', () {
      expect(normalizationGainDb(lufs: -23, peak: 1.0), 0.0);
    });

    test('病态值收敛到 [-60, +24]', () {
      expect(normalizationGainDb(lufs: 100), -60.0);
      expect(normalizationGainDb(lufs: -120), 24.0);
    });
  });
}
