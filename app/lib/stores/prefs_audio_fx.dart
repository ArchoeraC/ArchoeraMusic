// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'app_prefs.dart';

// ── 音频效果域键（audio. 前缀）──────────────────────────────────
const eqEnabledKey = 'audio.eq.enabled';
const eqGainsKey = 'audio.eq.gains';
const eqPreampKey = 'audio.eq.preamp';
const eqPresetKey = 'audio.eq.preset';
const limiterEnabledKey = 'audio.limiter';
const normalizationEnabledKey = 'audio.normalization';
const playbackSpeedKey = 'audio.speed';

// 参数化 EQ（方向① D1）与次声/低频管理（方向① D2）键。
const peqEnabledKey = 'audio.peq.enabled';
const peqBandsKey = 'audio.peq.bands';
const peqPreampKey = 'audio.peq.preamp';
const lowfreqEnabledKey = 'audio.lowfreq.enabled';
const lowfreqHpfFreqKey = 'audio.lowfreq.hpf.freq';
const lowfreqHpfOrderKey = 'audio.lowfreq.hpf.order';
const lowfreqBassGainKey = 'audio.lowfreq.bass.gain';
const lowfreqBassFreqKey = 'audio.lowfreq.bass.freq';

/// 均衡器频段数（对齐引擎 `EQ_BANDS = 10`）。
const int eqBandCount = 10;

/// 均衡器频段标签（Hz；仅展示用，顺序与引擎 `eqGains` 一致）。
const List<String> eqBandLabels = [
  '31Hz',
  '62Hz',
  '125Hz',
  '250Hz',
  '500Hz',
  '1kHz',
  '2kHz',
  '4kHz',
  '8kHz',
  '16kHz',
];

/// 增益/预增益范围（dB）。
const double eqGainMinDb = -12;
const double eqGainMaxDb = 12;

/// 播放速度范围（倍率）。
const double speedMin = 0.5;
const double speedMax = 2.0;

/// 均衡器预设（10 段增益，dB）。
const Map<String, List<double>> eqPresets = {
  'flat': [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
  'pop': [-1, 1, 2, 3, 2, 0, -1, -1, 0, 1],
  'rock': [4, 3, 1, -1, -2, -1, 1, 2, 3, 4],
  'jazz': [3, 2, 1, 2, 0, -1, -1, 0, 1, 2],
  'classical': [4, 3, 2, 0, 0, 0, -1, -1, 2, 3],
  'vocal': [-2, -1, 0, 2, 4, 4, 3, 1, 0, -1],
  'bass': [6, 5, 4, 2, 0, 0, 0, 0, 0, 0],
};

/// 全部预设 id（含自定义）。
const List<String> eqPresetIds = [
  'flat',
  'pop',
  'rock',
  'jazz',
  'classical',
  'vocal',
  'bass',
  'custom',
];

/// 归一化 10 段增益：长度对齐、范围收敛、非法值归零。
List<double> _normalizeEqGains(Object? value) {
  final list = value is List ? value : const [];
  return [
    for (var i = 0; i < eqBandCount; i++)
      (i < list.length && list[i] is num)
          ? (list[i] as num).toDouble().clamp(eqGainMinDb, eqGainMaxDb)
          : 0.0,
  ];
}

/// 音频效果偏好：10 段均衡器 / 预增益 / 限幅器 / 响度归一化 / 播放速度。
///
/// 引擎在会话内支持运行时命令（set_eq / set_normalization / set_limiter /
/// set_tempo_speed），改动即时生效，无需重启会话。
extension AudioFxPrefs on AppPrefs {
  /// 均衡器总开关（默认关）。
  bool get eqEnabled => data[eqEnabledKey] as bool? ?? false;

  /// 10 段增益（dB，-12~12，默认全 0）。
  List<double> get eqGains => _normalizeEqGains(data[eqGainsKey]);

  /// 预增益（dB，-12~12，默认 0）。
  double get eqPreampDb =>
      ((data[eqPreampKey] as num?)?.toDouble() ?? 0).clamp(
        eqGainMinDb,
        eqGainMaxDb,
      );

  /// 当前均衡器预设 id（'flat'/'pop'/.../'custom'；默认 flat）。
  String get eqPreset {
    final v = data[eqPresetKey];
    return (v is String && eqPresetIds.contains(v)) ? v : 'flat';
  }

  /// 限幅器（防削波；默认开，对齐引擎默认）。
  bool get limiterEnabled => data[limiterEnabledKey] as bool? ?? true;

  /// 响度归一化（跨曲目响度一致；默认关）。
  bool get normalizationEnabled =>
      data[normalizationEnabledKey] as bool? ?? false;

  /// 播放速度（0.5~2.0，默认 1.0；变速不变调）。
  double get playbackSpeed =>
      ((data[playbackSpeedKey] as num?)?.toDouble() ?? 1.0).clamp(
        speedMin,
        speedMax,
      );

  /// 设置均衡器（开关 / 增益 / 预增益 / 预设 / 限幅器）。
  AppPrefs copyWithEq({
    bool? enabled,
    List<double>? gains,
    double? preampDb,
    String? preset,
    bool? limiter,
  }) => AppPrefs(
    initialData: {
      ...data,
      eqEnabledKey: ?enabled,
      if (gains != null) eqGainsKey: _normalizeEqGains(gains),
      eqPreampKey: ?preampDb?.clamp(eqGainMinDb, eqGainMaxDb),
      if (preset != null && eqPresetIds.contains(preset))
        eqPresetKey: preset,
      limiterEnabledKey: ?limiter,
    },
  );

  /// 设置响度归一化开关。
  AppPrefs copyWithNormalization(bool value) =>
      AppPrefs(initialData: {...data, normalizationEnabledKey: value});

  /// 设置播放速度（0.5~2.0）。
  AppPrefs copyWithPlaybackSpeed(double value) => AppPrefs(
    initialData: {
      ...data,
      playbackSpeedKey: value.clamp(speedMin, speedMax),
    },
  );

  // ── 参数化 EQ（方向① D1）──────────────────────────────────────

  /// 参数化 EQ 总开关（默认关）。
  bool get peqEnabled => data[peqEnabledKey] as bool? ?? false;

  /// 参数化段列表（默认空；最多 [peqMaxBands] 段）。
  List<ParametricBand> get peqBands => _normalizePeqBands(data[peqBandsKey]);

  /// 参数化 EQ 预增益（dB，默认 0）。
  double get peqPreampDb =>
      ((data[peqPreampKey] as num?)?.toDouble() ?? 0).clamp(
        peqPreampMinDb,
        peqPreampMaxDb,
      );

  /// 设置参数化 EQ（开关 / 段列表 / 预增益）。
  AppPrefs copyWithPeq({
    bool? enabled,
    List<ParametricBand>? bands,
    double? preampDb,
  }) => AppPrefs(
    initialData: {
      ...data,
      peqEnabledKey: ?enabled,
      if (bands != null) peqBandsKey: _peqBandsToData(bands),
      peqPreampKey: ?preampDb?.clamp(peqPreampMinDb, peqPreampMaxDb),
    },
  );

  // ── 次声 / 低频管理（方向① D2）────────────────────────────────

  /// 低频管理总开关（默认关）。
  bool get lowfreqEnabled => data[lowfreqEnabledKey] as bool? ?? false;

  /// HPF 截止频率（Hz，默认 20）。
  double get lowfreqHpfFreq =>
      ((data[lowfreqHpfFreqKey] as num?)?.toDouble() ?? lowfreqHpfFreqDefault)
          .clamp(lowfreqHpfFreqMin, lowfreqHpfFreqMax);

  /// HPF 阶数（1 或 2，默认 2）。
  int get lowfreqHpfOrder =>
      ((data[lowfreqHpfOrderKey] as num?)?.toInt() ?? 2) == 1 ? 1 : 2;

  /// bass shelf 增益（dB，默认 0）。
  double get lowfreqBassGainDb =>
      ((data[lowfreqBassGainKey] as num?)?.toDouble() ?? 0).clamp(
        lowfreqBassGainMinDb,
        lowfreqBassGainMaxDb,
      );

  /// bass shelf 转折频率（Hz，默认 100）。
  double get lowfreqBassFreq =>
      ((data[lowfreqBassFreqKey] as num?)?.toDouble() ?? lowfreqBassFreqDefault)
          .clamp(lowfreqBassFreqMin, lowfreqBassFreqMax);

  /// 设置次声/低频管理。
  AppPrefs copyWithLowFreq({
    bool? enabled,
    double? hpfFreq,
    int? hpfOrder,
    double? bassGainDb,
    double? bassFreq,
  }) => AppPrefs(
    initialData: {
      ...data,
      lowfreqEnabledKey: ?enabled,
      lowfreqHpfFreqKey: ?hpfFreq?.clamp(lowfreqHpfFreqMin, lowfreqHpfFreqMax),
      if (hpfOrder != null) lowfreqHpfOrderKey: hpfOrder == 1 ? 1 : 2,
      lowfreqBassGainKey: ?bassGainDb?.clamp(
        lowfreqBassGainMinDb,
        lowfreqBassGainMaxDb,
      ),
      lowfreqBassFreqKey: ?bassFreq?.clamp(
        lowfreqBassFreqMin,
        lowfreqBassFreqMax,
      ),
    },
  );
}

// ── 参数化 EQ 数据模型与归一化（方向① D1）────────────────────────

/// 参数化 EQ 最大段数（对齐引擎 `PARAMETRIC_EQ_MAX_BANDS = 16`）。
const int peqMaxBands = 16;

/// 段类型（对齐引擎 enum ZkBandKind）。
const int peqKindPeak = 0;
const int peqKindLowShelf = 1;
const int peqKindHighShelf = 2;

/// 全部可选段类型（UI 下拉用）。
const List<int> peqKinds = [peqKindPeak, peqKindLowShelf, peqKindHighShelf];

const double peqFreqMin = 20;
const double peqFreqMax = 20000;
const double peqQMin = 0.1;
const double peqQMax = 12;
const double peqGainMinDb = -24;
const double peqGainMaxDb = 24;
const double peqPreampMinDb = -24;
const double peqPreampMaxDb = 24;

/// 单个参数化段 {kind, freq, Q, gain}。
class ParametricBand {
  const ParametricBand({
    this.kind = peqKindPeak,
    this.freq = 1000,
    this.q = 1.0,
    this.gainDb = 0,
  });

  final int kind;
  final double freq;
  final double q;
  final double gainDb;

  ParametricBand copyWith({int? kind, double? freq, double? q, double? gainDb}) =>
      ParametricBand(
        kind: kind ?? this.kind,
        freq: freq ?? this.freq,
        q: q ?? this.q,
        gainDb: gainDb ?? this.gainDb,
      );

  /// 引擎扁平编码 [kind, freq, q, gain]。
  List<double> toFlat() => [kind.toDouble(), freq, q, gainDb];
}

/// 归一化参数化段列表（兼容扁平 [kind,freq,q,gain] 存储；长度/范围收敛）。
List<ParametricBand> _normalizePeqBands(Object? value) {
  final list = value is List ? value : const [];
  final out = <ParametricBand>[];
  for (final e in list) {
    if (out.length >= peqMaxBands) break;
    if (e is List && e.length >= 4) {
      out.add(
        ParametricBand(
          kind: (e[0] as num).toInt().clamp(peqKindPeak, peqKindHighShelf),
          freq: (e[1] as num).toDouble().clamp(peqFreqMin, peqFreqMax),
          q: (e[2] as num).toDouble().clamp(peqQMin, peqQMax),
          gainDb: (e[3] as num).toDouble().clamp(peqGainMinDb, peqGainMaxDb),
        ),
      );
    }
  }
  return out;
}

List<List<double>> _peqBandsToData(List<ParametricBand> bands) => [
  for (final b in bands) b.toFlat(),
];

// ── 次声 / 低频管理常量（方向① D2）──────────────────────────────

const double lowfreqHpfFreqDefault = 20;
const double lowfreqHpfFreqMin = 10;
const double lowfreqHpfFreqMax = 200;
const double lowfreqBassFreqDefault = 100;
const double lowfreqBassFreqMin = 40;
const double lowfreqBassFreqMax = 500;
const double lowfreqBassGainMinDb = -24;
const double lowfreqBassGainMaxDb = 24;
