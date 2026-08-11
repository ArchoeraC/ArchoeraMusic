import 'app_prefs.dart';

// ── 强迫症设置键（对齐原项目 preset：Fuck DJ / 解锁脏话 / 标签与副标题）──
const fuckDjModeKey = 'preset.fuckDjMode';
const uncensorProfanityKey = 'preset.uncensorProfanity';
const hideVipTagKey = 'preset.hideVipTag';
const hideQualityTagKey = 'preset.hideQualityTag';
const showSubtitleKey = 'preset.showSubtitle';
const performanceModeKey = 'preset.performanceMode';

/// 预设域偏好（对齐原项目 preset）：播放过滤/歌词还原/列表标签/性能模式。
extension PresetPrefs on AppPrefs {
  /// Fuck DJ Mode：播放时自动跳过 DJ 混音 / 口水歌（默认关）。
  bool get fuckDjMode => data[fuckDjModeKey] as bool? ?? false;

  /// 解锁脏话：还原歌词中「f**k」等被星号遮盖的词（默认关）。
  bool get uncensorProfanity => data[uncensorProfanityKey] as bool? ?? false;

  /// 隐藏歌曲列表的 VIP / 付费标签（默认关 = 显示）。
  bool get hideVipTag => data[hideVipTagKey] as bool? ?? false;

  /// 隐藏歌曲列表的音质角标（默认关 = 显示）。
  bool get hideQualityTag => data[hideQualityTagKey] as bool? ?? false;

  /// 歌曲列表显示副标题（别名，如「(Live)」；默认开）。
  bool get showSubtitle => data[showSubtitleKey] as bool? ?? true;

  /// 性能模式：关闭所有动效并自动关闭音频频谱（默认关）。
  ///
  /// 开 = 全局隐式动效 0 时长 + 频谱开关视为关闭（FFT 轮询/渲染全停）。
  bool get performanceMode => data[performanceModeKey] as bool? ?? false;

  /// 强迫症设置（对齐原项目 preset：Fuck DJ / 解锁脏话 / 标签与副标题）。
  AppPrefs copyWithPreset({
    bool? performanceMode,
    bool? fuckDjMode,
    bool? uncensorProfanity,
    bool? hideVipTag,
    bool? hideQualityTag,
    bool? showSubtitle,
  }) => AppPrefs(
    initialData: {
      ...data,
      performanceModeKey: ?performanceMode,
      fuckDjModeKey: ?fuckDjMode,
      uncensorProfanityKey: ?uncensorProfanity,
      hideVipTagKey: ?hideVipTag,
      hideQualityTagKey: ?hideQualityTag,
      showSubtitleKey: ?showSubtitle,
    },
  );
}
