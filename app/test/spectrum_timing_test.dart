// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 频谱渲染时间学单测：帧间隔估计、帧间插值、攻/放按帧时长归一化。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/widgets/player/spectrum_view/spectrum_timing.dart';

void main() {
  group('spectrumInterpolationProgress', () {
    test('按实测间隔线性推进并夹紧到 [0,1]', () {
      expect(spectrumInterpolationProgress(1000, 1000, 50), 0);
      expect(spectrumInterpolationProgress(1025, 1000, 50), closeTo(0.5, 1e-9));
      expect(spectrumInterpolationProgress(1050, 1000, 50), 1);
      expect(spectrumInterpolationProgress(2000, 1000, 50), 1);
      // 位置回退（seek/切歌）不产生负进度。
      expect(spectrumInterpolationProgress(900, 1000, 50), 0);
    });

    test('间隔非法时直接饱和', () {
      expect(spectrumInterpolationProgress(1000, 900, 0), 1);
      expect(spectrumInterpolationProgress(1000, 900, -1), 1);
    });
  });

  group('攻/放归一化', () {
    test('60fps 帧时长下与原常量一致', () {
      expect(spectrumAttackFactor(spectrumFrameMs), closeTo(0.4, 1e-9));
      expect(spectrumDecayFactor(spectrumFrameMs), closeTo(0.88, 1e-9));
    });

    test('两帧时长等价于连续两次原系数', () {
      final twoFrames = spectrumFrameMs * 2;
      expect(spectrumAttackFactor(twoFrames), closeTo(1 - 0.6 * 0.6, 1e-9));
      expect(spectrumDecayFactor(twoFrames), closeTo(0.88 * 0.88, 1e-9));
    });

    test('高刷屏单帧系数更小，掉帧系数更大', () {
      expect(
        spectrumAttackFactor(spectrumFrameMs / 2),
        lessThan(spectrumAttackFactor(spectrumFrameMs)),
      );
      expect(
        spectrumAttackFactor(spectrumFrameMs * 2),
        greaterThan(spectrumAttackFactor(spectrumFrameMs)),
      );
      expect(
        spectrumDecayFactor(spectrumFrameMs / 2),
        greaterThan(spectrumDecayFactor(spectrumFrameMs)),
      );
    });

    test('极端 dt 被夹紧，不产生 NaN/越界', () {
      expect(spectrumAttackFactor(0), 0);
      expect(spectrumAttackFactor(10000), inInclusiveRange(0, 1));
      expect(spectrumDecayFactor(0), 1);
      expect(spectrumDecayFactor(10000), inInclusiveRange(0, 1));
    });
  });

  group('updateSpectrumInterval', () {
    test('档位切换（50 → 1000ms）直接跟随实测', () {
      expect(
        updateSpectrumInterval(50, 1000, configuredMs: 1000),
        closeTo(1000, 1e-9),
      );
    });

    test('小幅投递抖动做 EMA 平滑', () {
      final v = updateSpectrumInterval(50, 55, configuredMs: 50);
      expect(v, greaterThan(50));
      expect(v, lessThan(55));
    });

    test('超长空档（暂停/seek）回落到配置值', () {
      expect(
        updateSpectrumInterval(1000, 5000, configuredMs: 50),
        closeTo(50, 1e-9),
      );
      expect(
        updateSpectrumInterval(1000, 0, configuredMs: 300),
        closeTo(300, 1e-9),
      );
    });

    test('非法配置值被夹紧到合法区间', () {
      expect(
        updateSpectrumInterval(50, 0, configuredMs: 1),
        spectrumMinIntervalMs,
      );
      expect(
        updateSpectrumInterval(50, 0, configuredMs: 99999),
        spectrumMaxIntervalMs,
      );
    });
  });
}
