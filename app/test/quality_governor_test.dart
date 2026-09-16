// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 画质档位选择器回归测试：纯决策滞回、滑动窗口有界、降/升级与复位。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/render/quality_governor.dart';

void main() {
  const fast = Duration(milliseconds: 8);
  const slow = Duration(milliseconds: 33);

  group('QualityGovernor.decide（纯函数）', () {
    test('样本不足时不决策', () {
      expect(
        QualityGovernor.decide(
          RenderQualityTier.full,
          const Duration(milliseconds: 50),
          sampleCount: 2,
          minSamples: 10,
        ),
        RenderQualityTier.full,
      );
    });

    test('超过 downgradeThreshold 降一档', () {
      expect(
        QualityGovernor.decide(
          RenderQualityTier.full,
          const Duration(milliseconds: 21),
        ),
        RenderQualityTier.balanced,
      );
      expect(
        QualityGovernor.decide(
          RenderQualityTier.balanced,
          const Duration(milliseconds: 21),
        ),
        RenderQualityTier.performance,
      );
    });

    test('低于 upgradeThreshold 升一档', () {
      expect(
        QualityGovernor.decide(
          RenderQualityTier.performance,
          const Duration(milliseconds: 11),
        ),
        RenderQualityTier.balanced,
      );
      expect(
        QualityGovernor.decide(
          RenderQualityTier.balanced,
          const Duration(milliseconds: 11),
        ),
        RenderQualityTier.full,
      );
    });

    test('阈值带内保持（滞回，不抖动）', () {
      for (final tier in RenderQualityTier.values) {
        expect(
          QualityGovernor.decide(tier, const Duration(milliseconds: 15)),
          tier,
        );
      }
    });

    test('档位上下限饱和', () {
      expect(
        QualityGovernor.decide(
          RenderQualityTier.performance,
          const Duration(milliseconds: 99),
        ),
        RenderQualityTier.performance,
      );
      expect(
        QualityGovernor.decide(
          RenderQualityTier.full,
          const Duration(milliseconds: 1),
        ),
        RenderQualityTier.full,
      );
    });
  });

  group('QualityGovernor 窗口与档位', () {
    test('快帧保持 full', () {
      final governor = QualityGovernor();
      for (var i = 0; i < 200; i++) {
        governor.recordTotal(fast);
      }
      expect(governor.tier, RenderQualityTier.full);
    });

    test('持续慢帧依次降级 balanced 再到 performance', () {
      final governor = QualityGovernor();
      for (var i = 0; i < 30; i++) {
        governor.recordTotal(slow);
      }
      expect(governor.tier, RenderQualityTier.balanced);
      governor.recordTotal(slow);
      expect(governor.tier, RenderQualityTier.performance);
    });

    test('升至 full 需持续快帧（无即时抖动）', () {
      final governor = QualityGovernor(windowSize: 20, minSamples: 5);
      for (var i = 0; i < 40; i++) {
        governor.recordTotal(slow);
      }
      expect(governor.tier, RenderQualityTier.performance);

      governor.recordTotal(fast);
      expect(
        governor.tier,
        RenderQualityTier.performance,
        reason: '单帧快帧不应立即升级',
      );

      for (var i = 0; i < 30; i++) {
        governor.recordTotal(fast);
      }
      expect(governor.tier, RenderQualityTier.full);
    });

    test('升档先经 balanced 再回 full', () {
      final governor = QualityGovernor(windowSize: 20, minSamples: 5);
      for (var i = 0; i < 40; i++) {
        governor.recordTotal(slow);
      }
      expect(governor.tier, RenderQualityTier.performance);
      for (var i = 0; i < 30 && governor.tier != RenderQualityTier.full; i++) {
        governor.recordTotal(fast);
      }
      expect(governor.tier, RenderQualityTier.full);
    });

    test('窗口有界，只保留最近 windowSize 帧', () {
      final governor = QualityGovernor(windowSize: 10);
      for (var i = 0; i < 100; i++) {
        governor.recordTotal(fast);
      }
      expect(governor.sampleCount, 10);
    });

    test('旧样本被逐出，度量反映最近窗口', () {
      final governor = QualityGovernor(windowSize: 10, minSamples: 5);
      for (var i = 0; i < 50; i++) {
        governor.recordTotal(slow);
      }
      expect(
        governor.currentMetric,
        greaterThan(slow - const Duration(milliseconds: 1)),
      );
      for (var i = 0; i < 10; i++) {
        governor.recordTotal(fast);
      }
      expect(governor.currentMetric, fast);
    });

    test('可配置 EWMA 度量', () {
      final governor = QualityGovernor(
        metric: FrameTimeMetric.ewma,
        windowSize: 30,
        minSamples: 5,
      );
      for (var i = 0; i < 100; i++) {
        governor.recordTotal(fast);
      }
      expect(governor.tier, RenderQualityTier.full);
      for (var i = 0; i < 100; i++) {
        governor.recordTotal(slow);
      }
      expect(governor.tier, RenderQualityTier.performance);
    });

    test('reset 清空窗口与档位', () {
      final governor = QualityGovernor();
      for (var i = 0; i < 40; i++) {
        governor.recordTotal(slow);
      }
      expect(governor.tier, isNot(RenderQualityTier.full));

      governor.reset();
      expect(governor.sampleCount, 0);
      expect(governor.currentMetric, Duration.zero);
      expect(governor.tier, RenderQualityTier.full);
    });

    test('dispose 清空窗口与档位', () {
      final governor = QualityGovernor();
      for (var i = 0; i < 40; i++) {
        governor.recordTotal(slow);
      }
      governor.dispose();
      expect(governor.sampleCount, 0);
      expect(governor.tier, RenderQualityTier.full);
    });
  });
}
