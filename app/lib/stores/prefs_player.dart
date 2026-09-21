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
const sleepFinishTrackKey = 'player.sleepTimerFinishTrack';
const sleepTimerPresetsKey = 'player.sleepTimerPresets';
const sleepTimerCustomMinutesKey = 'player.sleepTimerCustomMinutes';
const enableSpectrumKey = 'player.enableSpectrum';
const coverBeatScaleKey = 'player.coverBeatScale';
const spectrumBarWidthKey = 'player.spectrumBarWidth';
const spectrumStyleKey = 'player.spectrumStyle';
const transitionStyleKey = 'player.transitionStyle';

// ── 进度条 / 播放条细节（强迫症）─────────────
const showProgressTooltipKey = 'player.showProgressTooltip';
const showProgressLyricKey = 'player.showProgressLyric';
const snapToLyricKey = 'player.snapToLyric';
const timeFormatKey = 'player.timeFormat';
const showPlaybackSourceKey = 'player.showPlaybackSource';

// ── 播放页封面布局（强迫症）─────────────
const coverLayoutKey = 'player.coverLayout';
const coverLyricRatioKey = 'player.coverLyricRatio';
const autoCenterCoverKey = 'player.autoCenterCover';
const followCoverColorKey = 'player.followCoverColor';

// ── 播放体验（强迫症）─────────────
const reverseSpectrumKey = 'player.spectrumReverse';
const autoImmersiveKey = 'player.autoImmersive';
const mediaSessionKey = 'system.mediaSession';
const registerProtocolKey = 'system.registerProtocol';
const crossfadeEnabledKey = 'player.fade';
const crossfadeDurationMsKey = 'player.fadeDuration';

// ── 播放页背景 ─────────────
const playerBgTypeKey = 'player.bgType';
const playerBgRippleSpeedKey = 'player.bgRippleSpeed';

/// 流体背景（对齐上游 player.playerBg*）：流速 / 渲染比例 / 帧率上限 /
/// 暂停冻结 / 低频节拍脉动。
const playerBgFlowSpeedKey = 'player.bgFlowSpeed';
const playerBgRenderScaleKey = 'player.bgRenderScale';
const playerBgFpsKey = 'player.bgFps';
const playerBgFreezeOnPauseKey = 'player.bgFreezeOnPause';
const playerBgBeatKey = 'player.bgBeat';

/// 自适应画质（依帧时间自动调整水纹渲染分辨率；默认关）。
const adaptiveRenderQualityKey = 'player.adaptiveRenderQuality';

// ── 音量与播放条显示 ─────────────
const volumeKey = 'player.volume';
const barLyricsKey = 'player.barLyrics';
const barSpectrumKey = 'player.barSpectrum';
const barEnhancedLyricsKey = 'lyrics.barEnhanced';
const showTranslationKey = 'lyrics.showTranslation';
const showRomanizationKey = 'lyrics.showRomanization';

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

/// 睡眠定时到点后是否等当前曲播完再暂停（默认开）。
///
/// 关闭则恢复旧行为：倒计时归零立即暂停（可能停在曲中）。
const bool defaultSleepFinishTrack = true;

/// 睡眠定时的快捷预设（分钟；可在设置里编辑；默认 15/30/60/90）。
///
/// 存盘为 `List<int>`；用户删光后为空列表（只保留「自定义…/播完当前曲/关闭」）。
const List<int> defaultSleepTimerPresets = [15, 30, 60, 90];

/// 睡眠定时分钟数的合法范围（自定义输入 / 预设编辑共用）。
const int minSleepTimerMinutes = 1;
const int maxSleepTimerMinutes = 600;

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
/// 'ripple' 水纹 / 'fluid' 流体；默认 'gradient'，保持原主题渐变观感）。
const String defaultPlayerBgType = 'gradient';
const Set<String> playerBgTypes = {
  'gradient',
  'blur',
  'solid',
  'ripple',
  'fluid',
};

/// 水纹流动速度（1~6，默认 3）。
const double defaultPlayerBgRippleSpeed = 3;

/// 流体流动速度（0.1~10，默认 4；对齐上游 player.playerBgFlowSpeed）。
const double defaultPlayerBgFlowSpeed = 4;

/// 流体渲染比例（0.5~2，默认 0.5；对齐上游 player.playerBgRenderScale，
/// 0.5 = 半分辨率离屏后放大，省填充率）。
const double defaultPlayerBgRenderScale = 0.5;

/// 流体帧率上限（24~120，默认 30；对齐上游 player.playerBgFps）。
const int defaultPlayerBgFps = 30;

/// 暂停时冻结流体流动（默认 false；对齐上游 player.playerBgFreezeOnPause，
/// 关闭时暂停后背景仍持续流动）。
const bool defaultPlayerBgFreezeOnPause = false;

/// 低频节拍脉动（默认 false；对齐上游 player.playerBgBeat，开启后按 80~180Hz
/// 低频脉冲调制流体旋转/缩放）。
const bool defaultPlayerBgBeat = false;

/// 自适应画质（默认关，保持旧行为）。开启后 [RenderQualityService] 依据
/// `FrameTiming` 在 full/balanced/performance 档位间切换，作为播放页水纹
/// 背景的 `renderScale`（见 docs/runtime-resource-optimization.md §4.5 / R4）。
const bool defaultAdaptiveRenderQuality = false;

/// 进度条悬停提示（默认开；鼠标悬停显示对应时间）。
const bool defaultShowProgressTooltip = true;

/// 全屏播放器进度条上方显示当前歌词（默认关）。
const bool defaultShowProgressLyric = false;

/// 拖动进度条松手吸附最近歌词行（默认关）。
const bool defaultSnapToLyric = false;

/// 播放时间格式（对齐上游 player.timeFormat）：
/// `current-total` 已播/总时长 / `remaining-total` 剩余/总时长 /
/// `current-remaining` 已播/剩余。
const String defaultTimeFormat = 'current-total';
const Set<String> timeFormats = {
  'current-total',
  'remaining-total',
  'current-remaining',
};

/// 播放条显示来源平台（默认关）。
const bool defaultShowPlaybackSource = false;

/// 播放页封面布局（`default` 左右分栏 / `fullscreen` 全屏封面）。
const String defaultCoverLayout = 'default';
const Set<String> coverLayouts = {'default', 'fullscreen'};

/// 封面/歌词宽度比例（0.3~0.6，默认 0.45；对齐上游 player.coverLyricRatio）。
const double defaultCoverLyricRatio = 0.45;

/// 无歌词时自动居中封面并隐藏歌词区（默认开；对齐上游 autoCenterCover）。
const bool defaultAutoCenterCover = true;

/// 歌词颜色跟随当前封面主色（默认关；对齐上游 followCoverColor）。
const bool defaultFollowCoverColor = false;

/// 反向频谱（水平翻转；默认关，对齐上游 reverseSpectrum）。
const bool defaultReverseSpectrum = false;

/// 自动沉浸（鼠标离开/静止时隐藏顶/底栏与鼠标；默认关，对齐上游 autoImmersive）。
const bool defaultAutoImmersive = false;

/// 同步到系统媒体会话（MPRIS/SMTC/Now Playing；默认开）。
const bool defaultMediaSession = true;

/// 注册 `archoera://` 协议处理程序（默认关；仅当前用户，免提权）。
const bool defaultRegisterProtocol = false;

/// 切歌淡入（新会话音量 0→目标；默认关，对齐上游 fadeEnabled）。
const bool defaultCrossfadeEnabled = false;

/// 切歌淡入时长（ms，100~2000，默认 400）。
const int defaultCrossfadeDurationMs = 400;

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
      ((data[pcmMemLimitMbKey] as num?)?.toInt() ?? defaultPcmMemLimitMb).clamp(
        1,
        1 << 18,
      );

  /// 启动时自动播放（恢复会话时自动续播）。
  bool get autoPlayOnLaunch =>
      data[autoPlayOnLaunchKey] as bool? ?? defaultAutoPlayOnLaunch;

  /// 会话记忆（记录/恢复上次播放现场）。
  bool get sessionMemory =>
      data[sessionMemoryKey] as bool? ?? defaultSessionMemory;

  /// 睡眠定时到点后是否等当前曲播完再暂停（默认开）。
  bool get sleepFinishTrack =>
      data[sleepFinishTrackKey] as bool? ?? defaultSleepFinishTrack;

  /// 睡眠定时快捷预设（分钟）：去重、clamp 到合法范围。
  ///
  /// 键缺失（旧数据）回退默认；键存在但为空列表表示用户删光了预设。
  List<int> get sleepTimerPresets {
    final raw = data[sleepTimerPresetsKey];
    if (raw is! List) return defaultSleepTimerPresets;
    final out = <int>[];
    for (final v in raw) {
      if (v is! num) continue;
      final m = v.round().clamp(minSleepTimerMinutes, maxSleepTimerMinutes);
      if (!out.contains(m)) out.add(m);
    }
    return out;
  }

  /// 最近一次自定义睡眠定时的分钟数；未设置/非法返回 null。
  int? get sleepTimerCustomMinutes {
    final v = data[sleepTimerCustomMinutesKey];
    if (v is! num) return null;
    final m = v.round();
    return (m < minSleepTimerMinutes || m > maxSleepTimerMinutes) ? null : m;
  }

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
  /// 'ripple' 水纹 / 'fluid' 流体；非法值回退默认 'gradient'）。
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

  /// 流体流动速度（0.1~10，默认 4）。
  double get playerBgFlowSpeed {
    final v = data[playerBgFlowSpeedKey] as num?;
    if (v == null) return defaultPlayerBgFlowSpeed;
    return v.toDouble().clamp(0.1, 10.0);
  }

  /// 流体渲染比例（0.5~2，默认 0.5）。
  double get playerBgRenderScale {
    final v = data[playerBgRenderScaleKey] as num?;
    if (v == null) return defaultPlayerBgRenderScale;
    return v.toDouble().clamp(0.5, 2.0);
  }

  /// 流体帧率上限（24~120，默认 30）。
  int get playerBgFps {
    final v = data[playerBgFpsKey] as num?;
    if (v == null) return defaultPlayerBgFps;
    return v.round().clamp(24, 120);
  }

  /// 暂停时冻结流体流动（默认 false）。
  bool get playerBgFreezeOnPause =>
      data[playerBgFreezeOnPauseKey] as bool? ?? defaultPlayerBgFreezeOnPause;

  /// 低频节拍脉动（默认 false）。
  bool get playerBgBeat =>
      data[playerBgBeatKey] as bool? ?? defaultPlayerBgBeat;

  /// 自适应画质（默认关）：开启后按帧时间自动调整水纹渲染分辨率。
  bool get adaptiveRenderQuality =>
      data[adaptiveRenderQualityKey] as bool? ?? defaultAdaptiveRenderQuality;

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

  /// 播放条迷你歌词显示翻译（默认开）；全屏播放器始终显示翻译，不受此项控制。
  bool get showTranslation => data[showTranslationKey] as bool? ?? true;

  /// 歌词显示音译（罗马音；默认关）。
  bool get showRomanization => data[showRomanizationKey] as bool? ?? false;

  /// 进度条悬停提示（默认开）。
  bool get showProgressTooltip =>
      data[showProgressTooltipKey] as bool? ?? defaultShowProgressTooltip;

  /// 全屏播放器进度条上方显示当前歌词（默认关）。
  bool get showProgressLyric =>
      data[showProgressLyricKey] as bool? ?? defaultShowProgressLyric;

  /// 拖动进度条吸附最近歌词行（默认关）。
  bool get snapToLyric => data[snapToLyricKey] as bool? ?? defaultSnapToLyric;

  /// 播放时间格式（非法值回退 [defaultTimeFormat]）。
  String get timeFormat {
    final v = data[timeFormatKey];
    if (timeFormats.contains(v)) return v as String;
    return defaultTimeFormat;
  }

  /// 播放条显示来源平台（默认关）。
  bool get showPlaybackSource =>
      data[showPlaybackSourceKey] as bool? ?? defaultShowPlaybackSource;

  /// 播放页封面布局（`default` 左右分栏 / `fullscreen` 全屏封面）。
  String get coverLayout {
    final v = data[coverLayoutKey];
    if (coverLayouts.contains(v)) return v as String;
    return defaultCoverLayout;
  }

  /// 封面/歌词宽度比例（0.3~0.6，默认 0.45）。
  double get coverLyricRatio {
    final v = data[coverLyricRatioKey] as num?;
    if (v == null) return defaultCoverLyricRatio;
    return v.toDouble().clamp(0.3, 0.6);
  }

  /// 无歌词时自动居中封面（默认开）。
  bool get autoCenterCover =>
      data[autoCenterCoverKey] as bool? ?? defaultAutoCenterCover;

  /// 歌词颜色跟随封面主色（默认关）。
  bool get followCoverColor =>
      data[followCoverColorKey] as bool? ?? defaultFollowCoverColor;

  /// 反向频谱（默认关）。
  bool get reverseSpectrum =>
      data[reverseSpectrumKey] as bool? ?? defaultReverseSpectrum;

  /// 自动沉浸（默认关）。
  bool get autoImmersive =>
      data[autoImmersiveKey] as bool? ?? defaultAutoImmersive;

  /// 同步系统媒体会话（默认开）。
  bool get mediaSessionEnabled =>
      data[mediaSessionKey] as bool? ?? defaultMediaSession;

  /// 注册 `archoera://` 协议处理程序（默认关）。
  bool get registerProtocol =>
      data[registerProtocolKey] as bool? ?? defaultRegisterProtocol;

  /// 切歌淡入开关（默认关）。
  bool get crossfadeEnabled =>
      data[crossfadeEnabledKey] as bool? ?? defaultCrossfadeEnabled;

  /// 切歌淡入时长（ms，100~2000，默认 400）。
  int get crossfadeDurationMs {
    final v = data[crossfadeDurationMsKey] as num?;
    if (v == null) return defaultCrossfadeDurationMs;
    return v.toInt().clamp(100, 2000);
  }

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
  }) => AppPrefs(
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

  /// 设置睡眠定时「到时播完当前曲再暂停」。
  AppPrefs copyWithSleepFinishTrack(bool value) =>
      AppPrefs(initialData: {...data, sleepFinishTrackKey: value});

  /// 设置睡眠定时快捷预设（分钟）。
  AppPrefs copyWithSleepTimerPresets(List<int> presets) =>
      AppPrefs(initialData: {...data, sleepTimerPresetsKey: presets});

  /// 记忆最近一次自定义睡眠定时（分钟数 clamp 到合法范围）。
  AppPrefs copyWithSleepTimerCustomMinutes(int minutes) => AppPrefs(
    initialData: {
      ...data,
      sleepTimerCustomMinutesKey: minutes.clamp(
        minSleepTimerMinutes,
        maxSleepTimerMinutes,
      ),
    },
  );

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

  AppPrefs copyWithShowRomanization(bool value) =>
      AppPrefs(initialData: {...data, showRomanizationKey: value});

  /// 设置播放页背景样式 / 水纹速度（非法样式不写入，getter 回退默认）。
  ///
  /// 流体参数同段写入：流速 0.1~10、渲染比例 0.5~2、帧率 24~120、
  /// 暂停冻结 / 节拍脉动开关。
  AppPrefs copyWithPlayerBackground({
    String? type,
    double? rippleSpeed,
    double? flowSpeed,
    double? renderScale,
    int? fps,
    bool? freezeOnPause,
    bool? beat,
  }) => AppPrefs(
    initialData: {
      ...data,
      if (playerBgTypes.contains(type)) playerBgTypeKey: type,
      playerBgRippleSpeedKey: ?rippleSpeed?.clamp(1.0, 6.0),
      playerBgFlowSpeedKey: ?flowSpeed?.clamp(0.1, 10.0),
      playerBgRenderScaleKey: ?renderScale?.clamp(0.5, 2.0),
      playerBgFpsKey: ?fps?.clamp(24, 120),
      playerBgFreezeOnPauseKey: ?freezeOnPause,
      playerBgBeatKey: ?beat,
    },
  );

  /// 设置自适应画质开关（默认关）。
  AppPrefs copyWithAdaptiveRenderQuality(bool value) =>
      AppPrefs(initialData: {...data, adaptiveRenderQualityKey: value});

  /// 设置进度条 / 播放条细节（悬停提示 / 进度歌词 / 吸附 / 时间格式 / 来源）。
  AppPrefs copyWithProgressDisplay({
    bool? showTooltip,
    bool? showLyric,
    bool? snapToLyric,
    String? timeFormat,
    bool? showSource,
  }) => AppPrefs(
    initialData: {
      ...data,
      showProgressTooltipKey: ?showTooltip,
      showProgressLyricKey: ?showLyric,
      snapToLyricKey: ?snapToLyric,
      if (timeFormats.contains(timeFormat)) timeFormatKey: timeFormat,
      showPlaybackSourceKey: ?showSource,
    },
  );

  /// 设置播放页封面布局（布局 / 占比 / 自动居中 / 跟随封面色）。
  AppPrefs copyWithCoverLayout({
    String? layout,
    double? ratio,
    bool? autoCenter,
    bool? followCoverColor,
  }) => AppPrefs(
    initialData: {
      ...data,
      if (coverLayouts.contains(layout)) coverLayoutKey: layout,
      coverLyricRatioKey: ?ratio?.clamp(0.3, 0.6),
      autoCenterCoverKey: ?autoCenter,
      followCoverColorKey: ?followCoverColor,
    },
  );

  /// 设置反向频谱开关（默认关）。
  AppPrefs copyWithReverseSpectrum(bool value) =>
      AppPrefs(initialData: {...data, reverseSpectrumKey: value});

  /// 设置自动沉浸开关（默认关）。
  AppPrefs copyWithAutoImmersive(bool value) =>
      AppPrefs(initialData: {...data, autoImmersiveKey: value});

  /// 设置系统媒体会话同步开关（默认开）。
  AppPrefs copyWithMediaSession(bool value) =>
      AppPrefs(initialData: {...data, mediaSessionKey: value});

  /// 设置 archoera:// 协议注册开关（默认关）。
  AppPrefs copyWithRegisterProtocol(bool value) =>
      AppPrefs(initialData: {...data, registerProtocolKey: value});

  /// 设置切歌淡入（开关 / 时长 ms）。
  AppPrefs copyWithCrossfade({bool? enabled, int? durationMs}) => AppPrefs(
    initialData: {
      ...data,
      crossfadeEnabledKey: ?enabled,
      crossfadeDurationMsKey: ?durationMs?.clamp(100, 2000),
    },
  );
}
