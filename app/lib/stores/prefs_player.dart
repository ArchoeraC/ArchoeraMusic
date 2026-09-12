// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'app_prefs.dart';

// ── 播放器域键（audio./player. 前缀）─────────────────────────────
const passthroughKey = 'audio.passthrough';
const engineKey = 'audio.engine';
const sinkKey = 'audio.sink';
const engineMemoryKey = 'audio.engineMemory';
const pcmMemPolicyKey = 'audio.pcmMemPolicy';
const pcmMemLimitMbKey = 'audio.pcmMemLimitMb';
const autoPlayOnLaunchKey = 'player.autoPlayOnLaunch';
const sessionMemoryKey = 'player.sessionMemory';
const enableSpectrumKey = 'player.enableSpectrum';
const coverBeatScaleKey = 'player.coverBeatScale';
const spectrumBarWidthKey = 'player.spectrumBarWidth';
const spectrumStyleKey = 'player.spectrumStyle';
const transitionStyleKey = 'player.transitionStyle';

// ── 播放页背景 ─────────────
const playerBgTypeKey = 'player.bgType';
const playerBgRippleSpeedKey = 'player.bgRippleSpeed';

// ── 音量与播放条显示 ─────────────
const volumeKey = 'player.volume';
const barLyricsKey = 'player.barLyrics';
const barSpectrumKey = 'player.barSpectrum';
const barEnhancedLyricsKey = 'lyrics.barEnhanced';
const showTranslationKey = 'lyrics.showTranslation';

/// 原音质直通（不转码）：开 = 引擎保持源采样率播放（Hi-Res/无损不降质，
/// 默认）；关 = 统一 48kHz 转码管线（与 Web/批量行为一致）。
const bool defaultPassthrough = true;

/// 解码引擎（'stable' = FFmpeg 稳定默认 / 'eraudio' = 自研实验性内核）。
/// 引擎在应用启动时加载，切换仅持久化偏好，需冷启动后由引擎会话读取生效。
const String defaultEngine = 'stable';
const Set<String> engineModes = {'stable', 'eraudio'};

/// 内存播放（不落盘）：默认开启。PCM 驻留进程内内存（引擎块列表），
/// 不写 stream.wav/.pcm；频谱经 pcm_window FFI。见 docs/audio-memory-playback.md。
const bool defaultEngineMemory = true;

/// PCM 内存保留策略：'auto'（按可用内存均衡，0.8 GiB 硬上限）/
/// 'limit'（用户指定 MB 上限）/ 'unlimited'（无上限，须显式警告）。默认 auto。
const String defaultPcmMemPolicy = 'auto';
const Set<String> pcmMemPolicies = {'auto', 'limit', 'unlimited'};

/// 'limit' 策略的默认保留上限（MB）。
const int defaultPcmMemLimitMb = 512;

/// 输出设备偏好（'' = 系统默认，遵循系统默认输出、不自动改道）。
///
/// 引擎在会话内按 id 显式输出到指定设备；Dart 持久化本值并即时下发
/// `set_sink`，无会话时下次会话创建后读取补发，重启后同样保持。
const String defaultSink = '';

/// 启动时自动播放（恢复会话时是否自动续播；默认关——仅恢复现场，点播放继续）。
const bool defaultAutoPlayOnLaunch = false;

/// 会话记忆（记录关闭前的最后一次播放现场：队列/位置/模式/音质；默认开）。
/// 关闭后不再保存也不恢复现场；「启动时自动播放」仅在开启记忆时才有意义。
const bool defaultSessionMemory = true;

/// 频谱可视化总开关（对齐原版 player.enableSpectrum，默认开）。
const bool defaultEnableSpectrum = true;

/// 封面跟随节拍缩放（对齐原版 PlayerCover 播放/暂停缩放之上叠加的
/// 鼓点脉冲；依赖 FFT 频谱数据，性能模式下自动停用，默认关）。
const bool defaultCoverBeatScale = false;

/// 频谱柱宽（px，1~12，对齐原版 player.spectrumBarWidth 默认 4）。
const int defaultSpectrumBarWidth = 4;

/// 频谱可视化样式（'bars' 经典条形 / 'wave' 双向波形 / 'waveUp' 单向波形；
/// 默认 bars）。三种为独立渲染效果，复用同一 FFT 数据缓冲，资源开销等同。
const String defaultSpectrumStyle = 'bars';
const Set<String> spectrumStyles = {'bars', 'wave', 'waveUp'};

/// 播放页背景样式（'gradient' 渐变 / 'blur' 模糊封面 / 'solid' 纯色 /
/// 'ripple' 水纹；默认 'gradient'，保持原主题渐变观感）。
const String defaultPlayerBgType = 'gradient';
const Set<String> playerBgTypes = {'gradient', 'blur', 'solid', 'ripple'};

/// 水纹流动速度（1~6，默认 3）。
const double defaultPlayerBgRippleSpeed = 3;

/// 播放器域偏好：直通/自动播放/会话记忆/频谱/封面动效/切歌动效/音量/播放条。
extension PlayerPrefs on AppPrefs {
  bool get passthrough => data[passthroughKey] as bool? ?? defaultPassthrough;

  /// 解码引擎（'stable' FFmpeg 稳定默认 / 'eraudio' 自研实验性；非法值回退）。
  String get engine {
    final v = data[engineKey];
    if (engineModes.contains(v)) return v as String;
    return defaultEngine;
  }

  /// 输出设备（'' = 系统默认；其余为引擎 list_sinks 返回的设备 id）。
  String get sink => data[sinkKey] as String? ?? defaultSink;

  /// 内存播放（不落盘）开关（默认开；会话级生效）。
  bool get engineMemoryPlay =>
      data[engineMemoryKey] as bool? ?? defaultEngineMemory;

  /// PCM 内存保留策略（'auto' / 'limit' / 'unlimited'；非法值回退 auto）。
  String get pcmMemPolicy {
    final v = data[pcmMemPolicyKey];
    if (pcmMemPolicies.contains(v)) return v as String;
    return defaultPcmMemPolicy;
  }

  /// 'limit' 策略的保留上限（MB；1 ~ 262144 收敛）。
  int get pcmMemLimitMb =>
      ((data[pcmMemLimitMbKey] as num?)?.toInt() ?? defaultPcmMemLimitMb)
          .clamp(1, 1 << 18);

  /// 启动时自动播放（恢复会话时自动续播）。
  bool get autoPlayOnLaunch =>
      data[autoPlayOnLaunchKey] as bool? ?? defaultAutoPlayOnLaunch;

  /// 会话记忆（记录/恢复上次播放现场）。
  bool get sessionMemory =>
      data[sessionMemoryKey] as bool? ?? defaultSessionMemory;

  bool get enableSpectrum =>
      data[enableSpectrumKey] as bool? ?? defaultEnableSpectrum;

  /// 封面跟随节拍缩放（鼓点脉冲；性能模式下视为关闭）。
  bool get coverBeatScale =>
      data[coverBeatScaleKey] as bool? ?? defaultCoverBeatScale;

  int get spectrumBarWidth {
    final v = data[spectrumBarWidthKey] as num?;
    if (v == null) return defaultSpectrumBarWidth;
    return v.round().clamp(1, 12);
  }

  /// 频谱可视化样式（'bars' / 'wave' / 'waveUp'；非法值回退默认 bars）。
  String get spectrumStyle {
    final v = data[spectrumStyleKey];
    if (spectrumStyles.contains(v)) return v as String;
    return defaultSpectrumStyle;
  }

  /// 封面切换动效样式（'scale' 缩放 / 'slide' 侧边滑动；默认 scale）。
  /// 对齐原版 settings.player.transitionStyle，全屏播放器切歌时
  /// 封面与歌曲信息的过渡动画。
  String get transitionStyle {
    final v = data[transitionStyleKey];
    if (v == 'scale' || v == 'slide') return v as String;
    return 'scale';
  }

  /// 播放页背景样式（'gradient' 渐变 / 'blur' 模糊封面 / 'solid' 纯色 /
  /// 'ripple' 水纹；非法值回退默认 'gradient'）。
  String get playerBgType {
    final v = data[playerBgTypeKey];
    if (playerBgTypes.contains(v)) return v as String;
    return defaultPlayerBgType;
  }

  /// 水纹流动速度（1~6，默认 3）。
  double get playerBgRippleSpeed {
    final v = data[playerBgRippleSpeedKey] as num?;
    if (v == null) return defaultPlayerBgRippleSpeed;
    return v.toDouble().clamp(1.0, 6.0);
  }

  /// 播放音量（0~1，默认 1.0）。
  ///
  /// 退出确认弹窗临时降半（duck）不落盘：此处始终是用户设定的音量，
  /// 弹窗关闭后 [duckVolume]/[restoreVolume] 回到该值。
  double get volume =>
      ((data[volumeKey] as num?)?.toDouble() ?? 1.0).clamp(0.0, 1.0);

  /// 播放条时间下方显示歌词（有歌词时替代迷你频谱；默认开）。
  bool get barLyrics => data[barLyricsKey] as bool? ?? true;

  /// 播放条迷你频谱（独立于播放页频谱开关；默认开）。
  bool get barSpectrum => data[barSpectrumKey] as bool? ?? true;

  /// 播放条高级歌词（默认开）：歌词含逐字时间轴（YRC/KRC）时，
  /// 播放条迷你歌词以卡拉OK 逐字高亮显示；关闭则始终显示普通整行歌词。
  bool get barEnhancedLyrics => data[barEnhancedLyricsKey] as bool? ?? true;

  /// 歌词显示翻译（播放条迷你歌词与全屏播放器；默认开）。
  bool get showTranslation => data[showTranslationKey] as bool? ?? true;

  AppPrefs copyWithPassthrough(bool value) =>
      AppPrefs(initialData: {...data, passthroughKey: value});

  /// 设置解码引擎（非法值不写入，getter 回退默认 stable）。
  AppPrefs copyWithEngine(String value) => AppPrefs(
    initialData: {...data, if (engineModes.contains(value)) engineKey: value},
  );

  /// 设置输出设备 id（'' = 系统默认；不校验，值仅来自引擎 list_sinks）。
  AppPrefs copyWithSink(String value) =>
      AppPrefs(initialData: {...data, sinkKey: value});

  /// 设置内存播放（不落盘）：开关 / PCM 保留策略（'auto'|'limit'|'unlimited'）/
  /// 自定义上限 MB（'limit' 生效；非法策略不写入，getter 回退 auto）。
  AppPrefs copyWithEngineMemory({
    bool? enabled,
    String? policy,
    int? limitMb,
  }) =>
      AppPrefs(
        initialData: {
          ...data,
          engineMemoryKey: ?enabled,
          if (pcmMemPolicies.contains(policy)) pcmMemPolicyKey: policy,
          pcmMemLimitMbKey: ?limitMb?.clamp(1, 1 << 18),
        },
      );

  AppPrefs copyWithAutoPlay(bool value) =>
      AppPrefs(initialData: {...data, autoPlayOnLaunchKey: value});

  AppPrefs copyWithMemory(bool value) =>
      AppPrefs(initialData: {...data, sessionMemoryKey: value});

  AppPrefs copyWithSpectrum({bool? enable, int? barWidth}) => AppPrefs(
    initialData: {
      ...data,
      enableSpectrumKey: ?enable,
      spectrumBarWidthKey: ?barWidth?.clamp(1, 12),
    },
  );

  /// 设置频谱可视化样式（非法值不写入，getter 回退默认 bars）。
  AppPrefs copyWithSpectrumStyle(String value) => AppPrefs(
    initialData: {
      ...data,
      if (spectrumStyles.contains(value)) spectrumStyleKey: value,
    },
  );

  AppPrefs copyWithCoverBeatScale(bool value) =>
      AppPrefs(initialData: {...data, coverBeatScaleKey: value});

  /// 设置封面切换动效样式（非法值不写入，getter 回退默认 scale）。
  AppPrefs copyWithTransitionStyle(String value) => AppPrefs(
    initialData: {
      ...data,
      if (value == 'scale' || value == 'slide') transitionStyleKey: value,
    },
  );

  /// 播放音量（0~1 收敛；退出确认弹窗的 duck 不落盘，不经此方法）。
  AppPrefs copyWithVolume(double value) =>
      AppPrefs(initialData: {...data, volumeKey: value.clamp(0.0, 1.0)});

  /// 播放条歌词 / 播放条频谱 / 播放条高级歌词开关。
  AppPrefs copyWithBarDisplay({
    bool? barLyrics,
    bool? barSpectrum,
    bool? barEnhancedLyrics,
  }) => AppPrefs(
    initialData: {
      ...data,
      barLyricsKey: ?barLyrics,
      barSpectrumKey: ?barSpectrum,
      barEnhancedLyricsKey: ?barEnhancedLyrics,
    },
  );

  AppPrefs copyWithShowTranslation(bool value) =>
      AppPrefs(initialData: {...data, showTranslationKey: value});

  /// 设置播放页背景样式 / 水纹速度（非法样式不写入，getter 回退默认）。
  AppPrefs copyWithPlayerBackground({String? type, double? rippleSpeed}) =>
      AppPrefs(
        initialData: {
          ...data,
          if (playerBgTypes.contains(type)) playerBgTypeKey: type,
          playerBgRippleSpeedKey: ?rippleSpeed?.clamp(1.0, 6.0),
        },
      );
}
