// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'app_prefs.dart';

// ── 歌词域键（lyrics. 前缀）────────────────────────────────────
const showLyricsKey = 'lyrics.showInPlayer';
const lyricFontSizeKey = 'lyrics.fontSize';
const lyricLineHeightKey = 'lyrics.lineHeight';
const lyricPlayedColorKey = 'lyrics.playedColor';
const lyricUnplayedColorKey = 'lyrics.unplayedColor';
const lyricFollowAccentKey = 'lyrics.followAccent';
const lyricAdaptiveFontSizeKey = 'lyrics.adaptiveFontSize';
const lyricFontWeightKey = 'lyrics.fontWeight';

// ── AMLL 歌词墙（AMLL 引擎）偏好键 ──────────────────────────────
const lyricEngineKey = 'lyrics.engine'; // 'simple' | 'amll'
const amllAlignFractionKey = 'amll.alignFraction';
const amllInactiveAlphaKey = 'amll.inactiveAlpha';
const amllWordSweepKey = 'amll.wordSweep';
const amllHidePassedKey = 'amll.hidePassed';
const amllEnableScaleKey = 'amll.enableScale';
const amllBlurQualityKey = 'amll.blurQuality'; // auto | fast | quality | off
const amllEnableBlurKey = 'amll.enableBlur'; // 旧键（仅用于迁移）
const amllSpringPresetKey = 'amll.springPreset';

// ── 歌词来源 / 格式顺序（强迫症）─────────────────────────────────
const lyricSourceOrderKey = 'lyrics.sourceOrder';
const lyricFormatOrderKey = 'lyrics.formatOrder';

// ── 歌词排除规则（强迫症）────────────────────────────────────────
const lyricExcludeEnabledKey = 'lyrics.excludeEnabled';
const lyricExcludeKeywordsKey = 'lyrics.excludeKeywords';
const lyricExcludeRegexesKey = 'lyrics.excludeRegexes';

/// 支持的在线歌词平台（与 Track.source 一致）；数组顺序即回退优先级。
const List<String> lyricPlatforms = ['netease', 'qqmusic', 'kugou'];

/// 默认歌词来源顺序（当前平台无歌词时按此顺序回退到其它平台）。
const List<String> defaultLyricSourceOrder = ['netease', 'qqmusic', 'kugou'];

/// 歌词格式标识：yrc/qrc/krc 为逐字富格式，lrc 为标准格式。
const List<String> lyricFormats = ['yrc', 'qrc', 'krc', 'lrc'];

/// 默认歌词格式优先级（逐字优先，其次标准 LRC）。
const List<String> defaultLyricFormatOrder = ['yrc', 'qrc', 'krc', 'lrc'];

/// 失焦档位可选值（`amll.blurQuality`；与 `LyricsBlurQuality` 一一对应）。
const List<String> amllBlurQualities = ['auto', 'fast', 'lite', 'quality', 'off'];

/// 归一化「顺序」列表：仅保留白名单内、去重，缺失项按 [fallback] 补齐。
List<String> _normalizeOrder(
  Object? value,
  List<String> allowed,
  List<String> fallback,
) {
  final out = <String>[];
  if (value is List) {
    for (final e in value) {
      if (e is String && allowed.contains(e) && !out.contains(e)) out.add(e);
    }
  }
  for (final e in fallback) {
    if (!out.contains(e)) out.add(e);
  }
  return out;
}

/// 归一化字符串列表（去空、trim；非法值返回空列表）。
List<String> _normalizeStringList(Object? value) {
  if (value is! List) return const [];
  return [
    for (final e in value)
      if (e is String && e.trim().isNotEmpty) e.trim(),
  ];
}

/// 由歌词字号自动换算行距（行距不再由用户手调，避免字号/行距组合失衡）。
///
/// 公式取**连续线性**：`行距 = 字号 × 1.6 + 12`（px），随字号单调平滑：
///   14px → 34.4px，18px → 40.8px，38px → 72.8px，60px → 108px。
/// 这为当前行下方的翻译小字预留了空间，且不随 clamp 造成跳变；
/// 仅保留一个很宽的上下限（34~160px）防极端值。
double lyricLineHeightFor(double fontSize) =>
    (fontSize * 1.6 + 12).clamp(34.0, 160.0);

/// 歌词域偏好：播放器内歌词/字号/已唱与未唱颜色（行距自动随字号）。
extension LyricsPrefs on AppPrefs {
  /// 播放器内显示歌词（当前行居中高亮 + 点击跳转）。
  bool get showLyricsInPlayer => data[showLyricsKey] as bool? ?? true;

  /// 播放器歌词字号（px，14~60，默认 18）。
  double get lyricFontSize {
    final v = data[lyricFontSizeKey] as num?;
    if (v == null) return 18;
    return v.toDouble().clamp(14, 60);
  }

  /// 播放器歌词行距：由 [lyricFontSize] 自动换算，不独立手调。
  double get lyricLineHeight => lyricLineHeightFor(lyricFontSize);

  /// 已唱行歌词颜色（ARGB；默认主色灰，对齐原版 desktopLyric.playedColor）。
  int get lyricPlayedColor => data[lyricPlayedColorKey] as int? ?? 0xFFD0D3DA;

  /// 未唱行歌词颜色（ARGB；默认次级前景，对齐原版 desktopLyric.unplayedColor）。
  int get lyricUnplayedColor =>
      data[lyricUnplayedColorKey] as int? ?? 0xFF9AA1B5;

  /// 已唱/高亮颜色跟随软件全局主题色（默认关；开则忽略 [lyricPlayedColor]）。
  bool get lyricFollowAccent => data[lyricFollowAccentKey] as bool? ?? false;

  /// 自适应字号（默认开）：歌词字号随窗口高度自动缩放（对齐原版 adaptiveFontSize）。
  bool get lyricAdaptiveFontSize =>
      data[lyricAdaptiveFontSizeKey] as bool? ?? true;

  /// 当前行歌词字重（400/500/600/700；非法值回退 600）。
  int get lyricFontWeight {
    final v = (data[lyricFontWeightKey] as num?)?.toInt();
    return (v == 400 || v == 500 || v == 600 || v == 700) ? v! : 600;
  }

  AppPrefs copyWithLyrics({bool? showInPlayer}) =>
      AppPrefs(initialData: {...data, showLyricsKey: ?showInPlayer});

  AppPrefs copyWithLyricStyle({
    double? fontSize,
    double? lineHeight,
    int? playedColor,
    int? unplayedColor,
    bool? followAccent,
    int? fontWeight,
  }) => AppPrefs(
    initialData: {
      ...data,
      lyricFontSizeKey: ?fontSize?.clamp(14, 60),
      lyricLineHeightKey: ?lineHeight?.clamp(42, 64),
      lyricPlayedColorKey: ?playedColor,
      lyricUnplayedColorKey: ?unplayedColor,
      lyricFollowAccentKey: ?followAccent,
      if (fontWeight == 400 ||
          fontWeight == 500 ||
          fontWeight == 600 ||
          fontWeight == 700)
        lyricFontWeightKey: fontWeight,
    },
  );

  /// 设置歌词自适应字号开关（默认开）。
  AppPrefs copyWithAdaptiveFontSize(bool value) =>
      AppPrefs(initialData: {...data, lyricAdaptiveFontSizeKey: value});
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

  /// 非激活行缩放（激活 1.0 / 非激活 0.97，弹簧平滑；默认开）。
  bool get amllEnableScale => data[amllEnableScaleKey] as bool? ?? true;

  /// 非激活行失焦档位（`auto`/`fast`/`quality`/`off`，默认 `auto`）。
  ///
  /// 兼容旧键：`amll.enableBlur == false` 视为 `off`（新键存在时以新键为准）。
  String get amllBlurQuality {
    final v = data[amllBlurQualityKey] as String?;
    if (v != null && amllBlurQualities.contains(v)) return v;
    return (data[amllEnableBlurKey] as bool? ?? true) ? 'auto' : 'off';
  }

  /// 弹簧预设（'default' 为 AMLL 自适应策略，其余为固定手感）。
  String get amllSpringPreset =>
      data[amllSpringPresetKey] as String? ?? 'default';

  AppPrefs copyWithAmll({
    String? engine,
    double? alignFraction,
    double? inactiveAlpha,
    bool? wordSweep,
    bool? hidePassed,
    bool? enableScale,
    String? blurQuality,
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
      amllBlurQualityKey: ?(blurQuality != null &&
              amllBlurQualities.contains(blurQuality)
          ? blurQuality
          : null),
      amllSpringPresetKey: ?springPreset,
    },
  );
}

/// 歌词来源 / 格式顺序与排除规则（强迫症设置）。
extension LyricPipelinePrefs on AppPrefs {
  /// 歌词来源回退顺序（合法平台、去重、缺失按默认补齐）。
  List<String> get lyricSourceOrder => _normalizeOrder(
    data[lyricSourceOrderKey],
    lyricPlatforms,
    defaultLyricSourceOrder,
  );

  /// 歌词格式优先级（合法格式、去重、缺失按默认补齐）。
  List<String> get lyricFormatOrder => _normalizeOrder(
    data[lyricFormatOrderKey],
    lyricFormats,
    defaultLyricFormatOrder,
  );

  /// 是否优先逐字格式：格式顺序中首个非 lrc（逐字）格式排在 lrc 之前。
  bool get preferWordByWord {
    final order = lyricFormatOrder;
    final rich = order.indexWhere((f) => f != 'lrc');
    final lrc = order.indexOf('lrc');
    if (rich < 0) return false;
    if (lrc < 0) return true;
    return rich < lrc;
  }

  /// 是否启用歌词排除规则（默认关）。
  bool get lyricExcludeEnabled =>
      data[lyricExcludeEnabledKey] as bool? ?? false;

  /// 排除关键词（行内含任意关键词即排除；不区分大小写）。
  List<String> get lyricExcludeKeywords =>
      _normalizeStringList(data[lyricExcludeKeywordsKey]);

  /// 排除正则（Dart RegExp 语法；解析失败视为未命中）。
  List<String> get lyricExcludeRegexes =>
      _normalizeStringList(data[lyricExcludeRegexesKey]);

  AppPrefs copyWithLyricSourceOrder(List<String> order) => AppPrefs(
    initialData: {
      ...data,
      lyricSourceOrderKey: _normalizeOrder(
        order,
        lyricPlatforms,
        defaultLyricSourceOrder,
      ),
    },
  );

  AppPrefs copyWithLyricFormatOrder(List<String> order) => AppPrefs(
    initialData: {
      ...data,
      lyricFormatOrderKey: _normalizeOrder(
        order,
        lyricFormats,
        defaultLyricFormatOrder,
      ),
    },
  );

  /// 设置歌词排除规则（启用开关 / 关键词 / 正则）。
  AppPrefs copyWithLyricExclude({
    bool? enabled,
    List<String>? keywords,
    List<String>? regexes,
  }) => AppPrefs(
    initialData: {
      ...data,
      lyricExcludeEnabledKey: ?enabled,
      if (keywords != null)
        lyricExcludeKeywordsKey: _normalizeStringList(keywords),
      if (regexes != null)
        lyricExcludeRegexesKey: _normalizeStringList(regexes),
    },
  );
}
