// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 频谱峰值保持线偏好：默认关、可开关、不污染其它频谱设置。
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
}
