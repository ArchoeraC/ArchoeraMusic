import 'app_prefs.dart';

// ── 歌词域键（lyrics. 前缀）────────────────────────────────────
const showLyricsKey = 'lyrics.showInPlayer';
const lyricFontSizeKey = 'lyrics.fontSize';
const lyricLineHeightKey = 'lyrics.lineHeight';
const lyricPlayedColorKey = 'lyrics.playedColor';
const lyricUnplayedColorKey = 'lyrics.unplayedColor';

// ── AMLL 歌词墙（AMLL 引擎）偏好键 ──────────────────────────────
const lyricEngineKey = 'lyrics.engine'; // 'simple' | 'amll'
const amllAlignFractionKey = 'amll.alignFraction';
const amllInactiveAlphaKey = 'amll.inactiveAlpha';
const amllWordSweepKey = 'amll.wordSweep';
const amllHidePassedKey = 'amll.hidePassed';
const amllEnableScaleKey = 'amll.enableScale';
const amllSpringPresetKey = 'amll.springPreset';

/// 由歌词字号自动换算行距（行距不再由用户手调，避免字号/行距组合失衡）。
/// 经验倍率 3.3（默认字号 18 → 约 59px 行距，歌词墙层次更舒展），
/// 下限 48 / 上限 110。
double lyricLineHeightFor(double fontSize) =>
    (fontSize * 3.3).clamp(48.0, 110.0);

/// 歌词域偏好：播放器内歌词/字号/已唱与未唱颜色（行距自动随字号）。
extension LyricsPrefs on AppPrefs {
  /// 播放器内显示歌词（当前行居中高亮 + 点击跳转）。
  bool get showLyricsInPlayer => data[showLyricsKey] as bool? ?? true;

  /// 播放器歌词字号（px，14~28，默认 18）。
  double get lyricFontSize {
    final v = data[lyricFontSizeKey] as num?;
    if (v == null) return 18;
    return v.toDouble().clamp(14, 28);
  }

  /// 播放器歌词行距：由 [lyricFontSize] 自动换算，不独立手调。
  double get lyricLineHeight => lyricLineHeightFor(lyricFontSize);

  /// 已唱行歌词颜色（ARGB；默认主色亮蓝，对齐原版 desktopLyric.playedColor）。
  int get lyricPlayedColor => data[lyricPlayedColorKey] as int? ?? 0xFF4DA3FF;

  /// 未唱行歌词颜色（ARGB；默认次级前景，对齐原版 desktopLyric.unplayedColor）。
  int get lyricUnplayedColor =>
      data[lyricUnplayedColorKey] as int? ?? 0xFF9AA1B5;

  AppPrefs copyWithLyrics({bool? showInPlayer}) =>
      AppPrefs(initialData: {...data, showLyricsKey: ?showInPlayer});

  AppPrefs copyWithLyricStyle({
    double? fontSize,
    double? lineHeight,
    int? playedColor,
    int? unplayedColor,
  }) => AppPrefs(
    initialData: {
      ...data,
      lyricFontSizeKey: ?fontSize?.clamp(14, 28),
      lyricLineHeightKey: ?lineHeight?.clamp(42, 64),
      lyricPlayedColorKey: ?playedColor,
      lyricUnplayedColorKey: ?unplayedColor,
    },
  );
}

/// AMLL 歌词墙偏好：引擎选择 + 布局/视觉参数。
extension AmllLyricsPrefs on AppPrefs {
  /// 歌词引擎：'simple'（旧实现）| 'amll'（Apple Music 风格歌词墙）。
  String get lyricEngine {
    final v = data[lyricEngineKey];
    return v == 'amll' ? 'amll' : 'simple';
  }

  /// 激活行锚定位置（0~1，占歌词区高度比例，默认 0.5 = 视口居中）。
  double get amllAlignFraction {
    final v = data[amllAlignFractionKey] as num?;
    if (v == null) return 0.5;
    return v.toDouble().clamp(0.15, 0.6);
  }

  /// 非激活行透明度（0~1，默认 0.45，兼顾 AMLL 层次与原版可读性）。
  double get amllInactiveAlpha {
    final v = data[amllInactiveAlphaKey] as num?;
    if (v == null) return 0.45;
    return v.toDouble().clamp(0.05, 1.0);
  }

  /// 逐字扫亮（卡拉 OK 逐字变色）。
  bool get amllWordSweep => data[amllWordSweepKey] as bool? ?? true;

  /// 已唱过的行淡出隐藏（默认关）。
  bool get amllHidePassed => data[amllHidePassedKey] as bool? ?? false;

  /// 非激活行缩放（激活 1 / 非激活 0.92，默认开）。
  bool get amllEnableScale => data[amllEnableScaleKey] as bool? ?? true;

  /// 弹簧预设（'default'|'smooth'|'responsive'|'jello'|'heavy'）。
  String get amllSpringPreset =>
      data[amllSpringPresetKey] as String? ?? 'default';

  AppPrefs copyWithAmll({
    String? engine,
    double? alignFraction,
    double? inactiveAlpha,
    bool? wordSweep,
    bool? hidePassed,
    bool? enableScale,
    String? springPreset,
  }) => AppPrefs(
    initialData: {
      ...data,
      lyricEngineKey: ?engine,
      amllAlignFractionKey: ?alignFraction?.clamp(0.15, 0.6),
      amllInactiveAlphaKey: ?inactiveAlpha?.clamp(0.05, 1.0),
      amllWordSweepKey: ?wordSweep,
      amllHidePassedKey: ?hidePassed,
      amllEnableScaleKey: ?enableScale,
      amllSpringPresetKey: ?springPreset,
    },
  );
}
