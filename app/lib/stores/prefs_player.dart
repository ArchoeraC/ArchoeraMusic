import 'app_prefs.dart';

// ── 播放器域键（audio./player. 前缀）─────────────────────────────
const passthroughKey = 'audio.passthrough';
const autoPlayOnLaunchKey = 'player.autoPlayOnLaunch';
const sessionMemoryKey = 'player.sessionMemory';
const enableSpectrumKey = 'player.enableSpectrum';
const coverBeatScaleKey = 'player.coverBeatScale';
const spectrumBarWidthKey = 'player.spectrumBarWidth';
const transitionStyleKey = 'player.transitionStyle';

// ── 音量与播放条显示（对齐 SPlayer-Next 音量体系）─────────────
const volumeKey = 'player.volume';
const barLyricsKey = 'player.barLyrics';
const barSpectrumKey = 'player.barSpectrum';
const barEnhancedLyricsKey = 'lyrics.barEnhanced';
const showTranslationKey = 'lyrics.showTranslation';

/// 原音质直通（不转码）：开 = 引擎保持源采样率播放（Hi-Res/无损不降质，
/// 默认）；关 = 统一 48kHz 转码管线（与 Web/批量行为一致）。
const bool defaultPassthrough = true;

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

/// 播放器域偏好：直通/自动播放/会话记忆/频谱/封面动效/切歌动效/音量/播放条。
extension PlayerPrefs on AppPrefs {
  bool get passthrough => data[passthroughKey] as bool? ?? defaultPassthrough;

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

  /// 封面切换动效样式（'scale' 缩放 / 'slide' 侧边滑动；默认 scale）。
  /// 对齐原版 settings.player.transitionStyle，全屏播放器切歌时
  /// 封面与歌曲信息的过渡动画。
  String get transitionStyle {
    final v = data[transitionStyleKey];
    if (v == 'scale' || v == 'slide') return v as String;
    return 'scale';
  }

  /// 播放音量（0~1，默认 1.0，对齐 SPlayer-Next status.volume）。
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
}
