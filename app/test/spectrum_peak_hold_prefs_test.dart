// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 频谱增强偏好：峰值保持线、AGC、γ、高频倾斜的默认值与开关。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/stores/app_prefs.dart';

void main() {
  group('spectrumPeakHold', () {
    test('默认关闭', () {
      expect(AppPrefs().spectrumPeakHold, isFalse);
    });

    test('开关可读回，且保留频谱开关与柱宽', () {
      final base = AppPrefs().copyWithSpectrum(enable: true, barWidth: 7);
      expect(base.enableSpectrum, isTrue);
      expect(base.spectrumBarWidth, 7);

      final on = base.copyWithSpectrumPeakHold(true);
      expect(on.spectrumPeakHold, isTrue);
      expect(on.enableSpectrum, isTrue);
      expect(on.spectrumBarWidth, 7);

      final off = on.copyWithSpectrumPeakHold(false);
      expect(off.spectrumPeakHold, isFalse);
    });

    test('缺省键回落到默认关', () {
      expect(AppPrefs(initialData: const {}).spectrumPeakHold, isFalse);
    });
  });

  group('spectrumAgc / spectrumGamma / spectrumTilt', () {
    test('默认全部关闭，数值保留默认值', () {
      final p = AppPrefs();
      expect(p.spectrumAgc, isFalse);
      expect(p.spectrumGamma, isFalse);
      expect(p.spectrumTilt, isFalse);
      expect(p.spectrumGammaValue, 0.9);
      expect(p.spectrumTiltValue, 0.5);
    });

    test('关闭时数值仍保留，重新开启后恢复', () {
      final p = AppPrefs().copyWithSpectrumEnhance(
        gamma: true,
        tilt: true,
        gammaValue: 0.75,
        tiltValue: 2.3,
      );
      expect(p.spectrumGammaValue, 0.75);
      expect(p.spectrumTiltValue, 2.3);

      final off = p.copyWithSpectrumEnhance(gamma: false, tilt: false);
      expect(off.spectrumGamma, isFalse);
      expect(off.spectrumTilt, isFalse);
      expect(off.spectrumGammaValue, 0.75);
      expect(off.spectrumTiltValue, 2.3);

      final on = off.copyWithSpectrumEnhance(gamma: true, tilt: true);
      expect(on.spectrumGammaValue, 0.75);
      expect(on.spectrumTiltValue, 2.3);
    });

    test('数值越界时按范围收敛', () {
      final p = AppPrefs().copyWithSpectrumEnhance(
        gammaValue: 99,
        tiltValue: -99,
      );
      expect(p.spectrumGammaValue, maxSpectrumGammaValue);
      expect(p.spectrumTiltValue, minSpectrumTiltValue);
    });

    test('可独立开关，且互不影响', () {
      final agc = AppPrefs().copyWithSpectrumEnhance(agc: true);
      expect(agc.spectrumAgc, isTrue);
      expect(agc.spectrumGamma, isFalse);
      expect(agc.spectrumTilt, isFalse);

      final gamma = agc.copyWithSpectrumEnhance(gamma: true);
      expect(gamma.spectrumAgc, isTrue);
      expect(gamma.spectrumGamma, isTrue);
      expect(gamma.spectrumTilt, isFalse);

      final tilt = gamma.copyWithSpectrumEnhance(tilt: true);
      expect(tilt.spectrumAgc, isTrue);
      expect(tilt.spectrumGamma, isTrue);
      expect(tilt.spectrumTilt, isTrue);

      final off = tilt.copyWithSpectrumEnhance(
        agc: false,
        gamma: false,
        tilt: false,
      );
      expect(off.spectrumAgc, isFalse);
      expect(off.spectrumGamma, isFalse);
      expect(off.spectrumTilt, isFalse);
    });
  });
}
