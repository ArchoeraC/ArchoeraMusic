// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:ui' show FramePhase, FrameTiming;

/// 单一耗时族在统计窗口内的分布摘要（单位均为微秒）。
///
/// 「耗时族」指帧流水线中的一段：UI 线程 build、raster 线程光栅、
/// build→raster 的排队间隔等；各自独立取样、独立计算分位数。
class FrameDurationStats {
  const FrameDurationStats({
    required this.count,
    required this.avgUs,
    required this.p50Us,
    required this.p95Us,
    required this.p99Us,
    required this.maxUs,
  });

  /// 样本数。
  final int count;

  /// 平均值。
  final double avgUs;

  /// p50 / p95 / p99 / 最大值（最近邻秩）。
  final int p50Us;
  final int p95Us;
  final int p99Us;
  final int maxUs;

  @override
  String toString() =>
      'avg ${_ms(avgUs)} / p50 ${_ms(p50Us.toDouble())} / '
      'p95 ${_ms(p95Us.toDouble())} / p99 ${_ms(p99Us.toDouble())} / '
      'max ${_ms(maxUs.toDouble())} (n=$count)';

  static String _ms(double us) => (us / 1000).toStringAsFixed(1);
}

/// 帧耗时族。
enum FrameDurationFamily {
  /// UI 线程 build（`FrameTiming.buildDuration`）。
  build,

  /// raster 线程光栅（`FrameTiming.rasterDuration`）。
  raster,

  /// build 结束到 raster 开始的排队间隔（帧调度/线程切换延迟）。
  rasterQueue,

  /// vsync 信号到 build 开始的分发延迟（`FrameTiming.vsyncOverhead`）。
  vsyncOverhead,

  /// vsync 到 raster 完成的全程（`FrameTiming.totalSpan`）。
  totalSpan,
}

/// 帧耗时分组统计器（渲染专项 P0 测量基建）。
///
/// 思路参考外部合成器渲染调研（见 `docs/rendering-reference-research.md` D1，
/// 自研实现）：按 UI / raster / 排队延迟三段分开取样并计算
/// avg/p50/p95/p99/max，而非只看单一 FPS 或总帧时间——UI 贵要靠缓存与批处理、
/// raster 贵要靠填充率与离屏层，两者的解法不同，必须分开归属。
///
/// 内存有界：环形保留最近 [capacity] 帧，超限丢弃最旧样本。
class FrameTimingStats {
  /// [capacity] 为环形样本上限（默认约 10s @60fps）。
  FrameTimingStats({this.capacity = 600}) : _samples = <FrameTiming>[];

  final int capacity;
  final List<FrameTiming> _samples;

  /// 当前样本数。
  int get sampleCount => _samples.length;

  /// 记录一帧；超出容量时丢弃最旧样本。
  void add(FrameTiming timing) {
    if (_samples.length >= capacity) {
      _samples.removeRange(0, _samples.length - capacity + 1);
    }
    _samples.add(timing);
  }

  /// 清空样本。
  void reset() => _samples.clear();

  /// 计算某个耗时族的分布；样本不足时返回 null。
  FrameDurationStats? statsFor(FrameDurationFamily family) {
    if (_samples.isEmpty) return null;
    // 各族样本的微秒整型值（Duration → µs，避免浮点累计误差）。
    final samples = <int>[];
    for (final t in _samples) {
      samples.add(_durationUs(t, family));
    }
    samples.sort();
    final n = samples.length;
    var sum = 0;
    for (final v in samples) {
      sum += v;
    }
    int nearestRank(double p) =>
        samples[((n - 1) * p).round().clamp(0, n - 1)];
    return FrameDurationStats(
      count: n,
      avgUs: sum / n,
      p50Us: nearestRank(0.50),
      p95Us: nearestRank(0.95),
      p99Us: nearestRank(0.99),
      maxUs: samples[n - 1],
    );
  }

  static int _durationUs(FrameTiming t, FrameDurationFamily family) {
    switch (family) {
      case FrameDurationFamily.build:
        return t.buildDuration.inMicroseconds;
      case FrameDurationFamily.raster:
        return t.rasterDuration.inMicroseconds;
      case FrameDurationFamily.rasterQueue:
        // 正常帧 rasterStart ≥ buildFinish；异常样本（如乱序时间戳）按 0 处理，
        // 不让单帧脏数据把整族分位数拉爆。
        final queueUs =
            t.timestampInMicroseconds(FramePhase.rasterStart) -
            t.timestampInMicroseconds(FramePhase.buildFinish);
        return queueUs < 0 ? 0 : queueUs;
      case FrameDurationFamily.vsyncOverhead:
        return t.vsyncOverhead.inMicroseconds;
      case FrameDurationFamily.totalSpan:
        return t.totalSpan.inMicroseconds;
    }
  }
}
