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
}
