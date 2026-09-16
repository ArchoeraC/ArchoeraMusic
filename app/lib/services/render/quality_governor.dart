// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:collection';
import 'dart:ui' show FrameTiming;

/// 自适应画质档位。
///
/// 由 [QualityGovernor] 依据帧时间窗口选择；本文件只做**决策**，不应用效果
/// （档位到具体渲染杠杆的映射见 [QualityGovernor] 文档注释）。
enum RenderQualityTier { full, balanced, performance }

/// 滑动窗口内帧时间的聚合度量方式。
enum FrameTimeMetric {
  /// 窗口内总帧时间的 p90（抗单帧抖动，默认）。
  p90,

  /// 总帧时间的指数加权移动平均（对持续劣化更敏感）。
  ewma,
}

/// 帧时间驱动的渲染画质档位选择器
/// （`docs/runtime-resource-optimization.md` §4.5 / 阶段 R4）。
///
/// 通过 [record] 接收 `dart:ui` 的 [FrameTiming]（取
/// `buildDuration + rasterDuration` 作为该帧总耗时），维护一个**有界**滑动窗口
/// （[windowSize]），并按 [metric] 聚合出度量值，再经 [decide] 选择档位：
/// - 度量值 > [downgradeThreshold] 且样本数 ≥ [minSamples] → 降一档；
/// - 度量值 < [upgradeThreshold] 且样本数 ≥ [minSamples] → 升一档；
/// - 处于两阈值之间则保持（**阈值带即滞回**，避免抖动）。
///
/// 构造时要求 `upgradeThreshold < downgradeThreshold`。窗口度量天然要求「持续」：
/// 少量快/慢帧不足以把窗口 p90（或 EWMA）推过阈值。
///
/// **档位 → 目标杠杆（仅文档，本类不应用）**
///
/// | tier | 着色器 | renderScale | ripple 上限 | 频谱 |
/// |---|---|---|---|---|
/// | [RenderQualityTier.full] | 开 | 1.0 | 24 | 开 |
/// | [RenderQualityTier.balanced] | 开 | 0.85 | 12 | 开 |
/// | [RenderQualityTier.performance] | 关（CPU 回退） | 0.7 | 6 | 关 |
///
/// 纯决策逻辑抽为静态 [decide]，可不依赖真实 binding 单测；[recordTotal] 是
/// 不涉及 [FrameTiming] 的注入缝隙（供内部 [record] 复用与测试）。
class QualityGovernor {
  QualityGovernor({
    this.windowSize = 120,
    this.metric = FrameTimeMetric.p90,
    this.downgradeThreshold = const Duration(milliseconds: 20),
    this.upgradeThreshold = const Duration(milliseconds: 12),
    this.minSamples = 30,
    this.ewmaAlpha = 0.2,
  }) : assert(windowSize > 0, 'windowSize 必须 > 0'),
       assert(minSamples > 0, 'minSamples 必须 > 0'),
       assert(
         upgradeThreshold < downgradeThreshold,
         'upgradeThreshold 必须小于 downgradeThreshold',
       ),
       assert(ewmaAlpha > 0 && ewmaAlpha <= 1, 'ewmaAlpha 必须落在 (0, 1]');

  /// 滑动窗口容量（保留最近这么多帧）。
  final int windowSize;

  /// 窗口聚合度量方式。
  final FrameTimeMetric metric;

  /// 超过此度量则考虑降档。
  final Duration downgradeThreshold;

  /// 低于此度量则考虑升档；必须小于 [downgradeThreshold]。
  final Duration upgradeThreshold;

  /// 触发决策所需的最小窗口样本数。
  final int minSamples;

  /// [FrameTimeMetric.ewma] 的平滑系数。
  final double ewmaAlpha;

  final ListQueue<Duration> _window = ListQueue<Duration>();
  double _ewmaMicros = 0;
  RenderQualityTier _tier = RenderQualityTier.full;

  /// 当前档位。
  RenderQualityTier get tier => _tier;

  /// 当前窗口内的样本数。
  int get sampleCount => _window.length;

  /// 当前窗口度量值；窗口为空时为 [Duration.zero]。
  Duration get currentMetric {
    if (_window.isEmpty) return Duration.zero;
    if (metric == FrameTimeMetric.ewma) {
      return Duration(microseconds: _ewmaMicros.round());
    }
    final sorted = _window.toList()..sort();
    final index = ((sorted.length - 1) * 0.9).round();
    return sorted[index];
  }

  /// 记录一帧 [FrameTiming]（`build + raster`）。
  void record(FrameTiming timing) =>
      recordTotal(timing.buildDuration + timing.rasterDuration);

  /// 记录一帧总耗时（不依赖 [FrameTiming]，供测试与内部复用）。
  void recordTotal(Duration total) {
    _window.addLast(total);
    while (_window.length > windowSize) {
      _window.removeFirst();
    }
    final micros = total.inMicroseconds.toDouble();
    _ewmaMicros = _window.length == 1
        ? micros
        : ewmaAlpha * micros + (1 - ewmaAlpha) * _ewmaMicros;
    _tier = decide(
      _tier,
      currentMetric,
      downgradeThreshold: downgradeThreshold,
      upgradeThreshold: upgradeThreshold,
      sampleCount: sampleCount,
      minSamples: minSamples,
    );
  }

  /// 清空窗口、度量与档位（回到 [RenderQualityTier.full]）。
  void reset() {
    _window.clear();
    _ewmaMicros = 0;
    _tier = RenderQualityTier.full;
  }

  /// 释放：等价于 [reset]。
  void dispose() => reset();

  /// 纯决策函数：不读写任何实例状态，便于单测。
  ///
  /// - 样本不足（[sampleCount] < [minSamples]）→ 保持 [current]；
  /// - [metric] > [downgradeThreshold] → 降一档（最低 [RenderQualityTier.performance]）；
  /// - [metric] < [upgradeThreshold] → 升一档（最高 [RenderQualityTier.full]）；
  /// - 否则保持（滞回带）。
  static RenderQualityTier decide(
    RenderQualityTier current,
    Duration metric, {
    Duration downgradeThreshold = const Duration(milliseconds: 20),
    Duration upgradeThreshold = const Duration(milliseconds: 12),
    int sampleCount = 1,
    int minSamples = 1,
  }) {
    if (sampleCount < minSamples) return current;
    if (metric > downgradeThreshold) return _downgrade(current);
    if (metric < upgradeThreshold) return _upgrade(current);
    return current;
  }

  static RenderQualityTier _downgrade(RenderQualityTier tier) => switch (tier) {
    RenderQualityTier.full => RenderQualityTier.balanced,
    RenderQualityTier.balanced => RenderQualityTier.performance,
    RenderQualityTier.performance => RenderQualityTier.performance,
  };

  static RenderQualityTier _upgrade(RenderQualityTier tier) => switch (tier) {
    RenderQualityTier.performance => RenderQualityTier.balanced,
    RenderQualityTier.balanced => RenderQualityTier.full,
    RenderQualityTier.full => RenderQualityTier.full,
  };
}
