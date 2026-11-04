// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 一帧频谱（引擎 `fft` 事件的前端契约：128 bins，对数映射 40~16000Hz，
/// 归一化 [0,1]，见 docs/spectrum-analyzer.md §6.2）。
///
/// 只由 `EngineFft` 事件创建（引擎推送 → [PlaybackState.fft]），前端不再
/// 拉 PCM / 调 FFI。
class FftFrame {
  const FftFrame({
    required this.ldata,
    required this.rdata,
    this.lpeak = const <double>[],
    this.rpeak = const <double>[],
    this.beatStrength = 0,
    this.intervalMs = 50,
    this.seq = 0,
    this.minHz = 40,
    this.maxHz = 16000,
  });

  final List<double> ldata;
  final List<double> rdata;

  /// 引擎计算的峰值保持线（与 [ldata]/[rdata] 同长度；空 = 无峰值数据）。
  final List<double> lpeak;
  final List<double> rpeak;

  /// 生产端的目标推送间隔（ms，50/300/1000）。渲染端据此计算帧间插值
  /// 进度，不再写死 50ms（否则插值提前走完、后段停住）。
  final int intervalMs;

  /// 本帧脉冲强度 0~1（引擎节拍检测结果——对数谱通量突增的强度；
  /// 封面跟随节奏缩放按此区分脉冲大小）。无脉冲为 0。
  final double beatStrength;

  /// 单调递增的帧序号（引擎重启/丢帧检测用）。
  final int seq;

  /// 本帧频谱覆盖的最低频率（Hz，v2 默认 40）。
  final int minHz;

  /// 本帧频谱覆盖的最高频率（Hz，v2 默认 16000）。
  final int maxHz;

  /// 本帧是否有脉冲（[beatStrength] > 0）。
  bool get beat => beatStrength > 0;

  /// 附带推送间隔的副本（列表缓冲共享，不复制频谱数据）。
  FftFrame withIntervalMs(int intervalMs) => FftFrame(
    ldata: ldata,
    rdata: rdata,
    lpeak: lpeak,
    rpeak: rpeak,
    beatStrength: beatStrength,
    intervalMs: intervalMs,
    seq: seq,
    minHz: minHz,
    maxHz: maxHz,
  );
}
