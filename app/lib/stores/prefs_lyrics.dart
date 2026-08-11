import 'app_prefs.dart';

// ── 歌词域键（lyrics. 前缀）────────────────────────────────────
const showLyricsKey = 'lyrics.showInPlayer';
const lyricFontSizeKey = 'lyrics.fontSize';
const lyricLineHeightKey = 'lyrics.lineHeight';
const lyricPlayedColorKey = 'lyrics.playedColor';
const lyricUnplayedColorKey = 'lyrics.unplayedColor';

/// 歌词域偏好：播放器内歌词/字号/行高/已唱与未唱颜色。
extension LyricsPrefs on AppPrefs {
  /// 播放器内显示歌词（当前行居中高亮 + 点击跳转）。
  bool get showLyricsInPlayer => data[showLyricsKey] as bool? ?? true;

  /// 播放器歌词字号（px，14~28，默认 18）。
  double get lyricFontSize {
    final v = data[lyricFontSizeKey] as num?;
    if (v == null) return 18;
    return v.toDouble().clamp(14, 28);
  }

  /// 播放器歌词行高（px，42~64，默认 52）。
  double get lyricLineHeight {
    final v = data[lyricLineHeightKey] as num?;
    if (v == null) return 52;
    return v.toDouble().clamp(42, 64);
  }

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
