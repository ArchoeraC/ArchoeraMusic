import 'app_prefs.dart';

// ── 强迫症设置键（对齐原项目 preset：Fuck DJ / 解锁脏话 / 标签与副标题）──
const fuckDjModeKey = 'preset.fuckDjMode';
const uncensorProfanityKey = 'preset.uncensorProfanity';
const hideVipTagKey = 'preset.hideVipTag';
const hideQualityTagKey = 'preset.hideQualityTag';
const showSubtitleKey = 'preset.showSubtitle';
const performanceModeKey = 'preset.performanceMode';
const energySavingModeKey = 'preset.energySavingMode';
const songCacheEnabledKey = 'preset.songCacheEnabled';
const songCacheLimitMiBKey = 'preset.songCacheLimitMiB';
const lyricCacheLimitMiBKey = 'preset.lyricCacheLimitMiB';
const imageCacheLimitMiBKey = 'preset.imageCacheLimitMiB';

/// 歌曲磁盘缓存下限（MiB）：按现代流媒体数据方案计算——
/// 320kbps 高品 ≈ 2.4 MiB/分钟，一首标准 4 分钟曲目 ≈ 10 MiB；
/// 16 MiB 能完整缓存 ≥1 首高品曲目，取整作为可调下限。
const songCacheLimitMinMiB = 16;
const songCacheLimitMaxMiB = 4096;
const songCacheLimitStepMiB = 16;
const songCacheLimitDefaultMiB = 512;

/// 歌词缓存上限（MiB，进程内内存缓存）：纯文本平均 ~1.5KB/首（含翻译），
/// 1 MiB ≈ 700 首，足够覆盖整段歌单浏览且不占资源，取作下限。
const lyricCacheLimitMinMiB = 1;
const lyricCacheLimitMaxMiB = 64;

/// 封面图片缓存上限（MiB，进程内 ImageCache）：现代流媒体封面典型
/// 640×640 JPEG ≈ 40-120KB，8 MiB ≈ 60-100 张，够一屏网格 + 滚动预取，
/// 取作下限。
const imageCacheLimitMinMiB = 8;
const imageCacheLimitMaxMiB = 1024;
const imageCacheLimitStepMiB = 8;

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

  /// 节能模式：降低频谱取帧频率（约 300ms 一帧）以节省 CPU（默认关）。
  ///
  /// 关 = 取帧保持 100ms 基线（性能优化后的默认）。开 = 进一步降帧，
  /// 频谱刷新变慢但 CPU/IO 负担更低；频谱渲染与插值协商不受影响。
  bool get energySavingMode => data[energySavingModeKey] as bool? ?? false;

  /// 歌曲磁盘缓存：播放过的在线歌曲缓存到本地（默认开）。
  ///
  /// 开 = 播放未命中时后台下载整曲入缓存，重播直接读本地文件
  /// （省流量/加速/断网可播）；关 = 全部走在线 URL 实时拉取。
  bool get songCacheEnabled => data[songCacheEnabledKey] as bool? ?? true;

  /// 歌曲磁盘缓存上限（MiB，默认 512；下限 16 见 [songCacheLimitMinMiB]）。
  ///
  /// 超限时按 LRU（最近最少访问）淘汰最旧曲目，保证磁盘占用不超过上限。
  int get songCacheLimitMiB {
    final v = data[songCacheLimitMiBKey] as num?;
    if (v == null) return songCacheLimitDefaultMiB;
    return v.toInt().clamp(songCacheLimitMinMiB, songCacheLimitMaxMiB);
  }

  /// 歌词缓存上限（MiB，进程内内存）：null = 无上限；默认 = 最小值
  /// [lyricCacheLimitMinMiB]。超限时按 LRU 淘汰最旧歌词。
  int? get lyricCacheLimitMiB {
    final v = data[lyricCacheLimitMiBKey] as num?;
    if (v == null) return lyricCacheLimitMinMiB;
    final n = v.toInt();
    if (n <= 0) return null; // 无上限
    return n.clamp(lyricCacheLimitMinMiB, lyricCacheLimitMaxMiB);
  }

  /// 封面图片缓存上限（MiB，进程内 ImageCache）：null = 无上限；默认 =
  /// 最小值 [imageCacheLimitMinMiB]。超限时按 LRU 逐出封面图。
  int? get imageCacheLimitMiB {
    final v = data[imageCacheLimitMiBKey] as num?;
    if (v == null) return imageCacheLimitMinMiB;
    final n = v.toInt();
    if (n <= 0) return null; // 无上限
    return n.clamp(imageCacheLimitMinMiB, imageCacheLimitMaxMiB);
  }

  /// 强迫症设置（对齐原项目 preset：Fuck DJ / 解锁脏话 / 标签与副标题）。
  AppPrefs copyWithPreset({
    bool? performanceMode,
    bool? energySavingMode,
    bool? songCacheEnabled,
    int? songCacheLimitMiB,
    int? lyricCacheLimitMiB,
    int? imageCacheLimitMiB,
    bool? fuckDjMode,
    bool? uncensorProfanity,
    bool? hideVipTag,
    bool? hideQualityTag,
    bool? showSubtitle,
  }) => AppPrefs(
    initialData: {
      ...data,
      performanceModeKey: ?performanceMode,
      energySavingModeKey: ?energySavingMode,
      songCacheEnabledKey: ?songCacheEnabled,
      songCacheLimitMiBKey: ?songCacheLimitMiB,
      lyricCacheLimitMiBKey: ?lyricCacheLimitMiB,
      imageCacheLimitMiBKey: ?imageCacheLimitMiB,
      fuckDjModeKey: ?fuckDjMode,
      uncensorProfanityKey: ?uncensorProfanity,
      hideVipTagKey: ?hideVipTag,
      hideQualityTagKey: ?hideQualityTag,
      showSubtitleKey: ?showSubtitle,
    },
  );
}
