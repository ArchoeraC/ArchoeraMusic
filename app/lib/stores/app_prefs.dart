import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' show Color;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/playback/playback_session.dart';
import 'data_dir.dart';

/// 下载音质档位（高→低，Rust 内部按此顺序自动降级）。
/// 与 [qualityLabels]（netease/track.dart）键一致；集中定义避免散落字面量。
const downloadQualityLevels = <String>['hi-res', 'lossless', 'hq', 'sq', 'lq'];

/// 应用偏好（轻量 JSON 文件持久化，存数据目录 `prefs.json`）。
///
/// 架构决策：Dart 只持轻量 UI 态/偏好（队列/历史/UI 偏好存 Dart 本地）；
/// 此处为 UI 偏好的最小实现，避免为单个开关引入 Hive/drift 依赖。
class AppPrefs {
  AppPrefs({Map<String, dynamic>? data}) : _data = data ?? {};

  static const _passthroughKey = 'audio.passthrough';
  static const _autoPlayOnLaunchKey = 'player.autoPlayOnLaunch';
  static const _sessionMemoryKey = 'player.sessionMemory';
  static const _enableSpectrumKey = 'player.enableSpectrum';
  static const _coverBeatScaleKey = 'player.coverBeatScale';
  static const _spectrumBarWidthKey = 'player.spectrumBarWidth';
  static const _transitionStyleKey = 'player.transitionStyle';
  static const _accentKey = 'appearance.accent';
  static const _themeSourceKey = 'appearance.themeSource';
  static const _globalTintKey = 'appearance.globalTint';
  static const _appearanceStyleKey = 'appearance.appearanceStyle';
  static const _backgroundImageKey = 'appearance.backgroundImage';
  static const _backgroundBlurKey = 'appearance.backgroundBlur';
  static const _backgroundDimKey = 'appearance.backgroundDim';
  static const _backgroundScaleKey = 'appearance.backgroundScale';
  static const _routeTransitionKey = 'appearance.routeTransition';
  static const _sidebarCollapsedKey = 'appearance.sidebarCollapsed';
  static const _sidebarNavStyleKey = 'appearance.sidebarNavStyle';
  static const _localeKey = 'appearance.locale';
  static const _floatingBarKey = 'appearance.floatingPlayerBar';
  static const _fontFamilyKey = 'appearance.fontFamily';
  static const _coverRadiusKey = 'appearance.coverRadius';
  static const _showLyricsKey = 'lyrics.showInPlayer';
  static const _lyricFontSizeKey = 'lyrics.fontSize';
  static const _lyricLineHeightKey = 'lyrics.lineHeight';
  static const _lyricPlayedColorKey = 'lyrics.playedColor';
  static const _lyricUnplayedColorKey = 'lyrics.unplayedColor';
  static const _downloadRootKey = 'download.rootDir';
  static const _downloadMaxConcurrentKey = 'download.maxConcurrent';
  static const _downloadSubdirKey = 'download.subdirStrategy';
  static const _downloadQualityKey = 'download.quality';
  static const _downloadSpeedLimitKey = 'download.speedLimit';
  static const _downloadFilenameTemplateKey = 'download.filenameTemplate';
  static const _downloadHistoryLimitKey = 'download.historyLimit';
  static const _closeBehaviorKey = 'app.closeBehavior';
  static const _developerModeKey = 'app.developerMode';

  // ── 音量与播放条显示（对齐 SPlayer-Next 音量体系）─────────────
  static const _volumeKey = 'player.volume';
  static const _barLyricsKey = 'player.barLyrics';
  static const _barSpectrumKey = 'player.barSpectrum';
  static const _barEnhancedLyricsKey = 'lyrics.barEnhanced';
  static const _showTranslationKey = 'lyrics.showTranslation';

  // ── 刮削设置（对齐 SPlayer-Next 刮削器多源方案）──
  // 目录留空 = 使用媒体库扫描目录；数据源开关默认全开。
  static const _scrapeDirsKey = 'scrape.dirs';
  static const _scrapeUseMusicBrainzKey = 'scrape.useMusicBrainz';
  static const _scrapeUseDeezerKey = 'scrape.useDeezer';
  static const _scrapeUseItunesKey = 'scrape.useItunes';
  static const _scrapeUseNeteaseKey = 'scrape.useNetease';
  static const _scrapeUseQQMusicKey = 'scrape.useQQMusic';
  static const _scrapeUseKugouKey = 'scrape.useKugou';
  static const _scrapeUseKuwoKey = 'scrape.useKuwo';
  static const _scrapeUseMiguKey = 'scrape.useMigu';
  static const _scrapeUseAcoustIDKey = 'scrape.useAcoustID';

  // ── 强迫症设置（对齐原项目 preset：Fuck DJ / 解锁脏话 / 标签与副标题）──
  static const _fuckDjModeKey = 'preset.fuckDjMode';
  static const _uncensorProfanityKey = 'preset.uncensorProfanity';
  static const _hideVipTagKey = 'preset.hideVipTag';
  static const _hideQualityTagKey = 'preset.hideQualityTag';
  static const _showSubtitleKey = 'preset.showSubtitle';
  static const _performanceModeKey = 'preset.performanceMode';

  /// 原音质直通（不转码）：开 = 引擎保持源采样率播放（Hi-Res/无损不降质，
  /// 默认）；关 = 统一 48kHz 转码管线（与 Web/批量行为一致）。
  static const bool defaultPassthrough = true;

  /// 启动时自动播放（恢复会话时是否自动续播；默认关——仅恢复现场，点播放继续）。
  static const bool defaultAutoPlayOnLaunch = false;

  /// 会话记忆（记录关闭前的最后一次播放现场：队列/位置/模式/音质；默认开）。
  /// 关闭后不再保存也不恢复现场；「启动时自动播放」仅在开启记忆时才有意义。
  static const bool defaultSessionMemory = true;

  /// 频谱可视化总开关（对齐原版 player.enableSpectrum，默认开）。
  static const bool defaultEnableSpectrum = true;

  /// 封面跟随节拍缩放（对齐原版 PlayerCover 播放/暂停缩放之上叠加的
  /// 鼓点脉冲；依赖 FFT 频谱数据，性能模式下自动停用，默认关）。
  static const bool defaultCoverBeatScale = false;

  /// 频谱柱宽（px，1~12，对齐原版 player.spectrumBarWidth 默认 4）。
  static const int defaultSpectrumBarWidth = 4;

  final Map<String, dynamic> _data;

  bool get passthrough => _data[_passthroughKey] as bool? ?? defaultPassthrough;

  /// 启动时自动播放（恢复会话时自动续播）。
  bool get autoPlayOnLaunch =>
      _data[_autoPlayOnLaunchKey] as bool? ?? defaultAutoPlayOnLaunch;

  /// 会话记忆（记录/恢复上次播放现场）。
  bool get sessionMemory =>
      _data[_sessionMemoryKey] as bool? ?? defaultSessionMemory;

  bool get enableSpectrum =>
      _data[_enableSpectrumKey] as bool? ?? defaultEnableSpectrum;

  /// 封面跟随节拍缩放（鼓点脉冲；性能模式下视为关闭）。
  bool get coverBeatScale =>
      _data[_coverBeatScaleKey] as bool? ?? defaultCoverBeatScale;

  int get spectrumBarWidth {
    final v = _data[_spectrumBarWidthKey] as num?;
    if (v == null) return defaultSpectrumBarWidth;
    return v.round().clamp(1, 12);
  }

  /// 封面切换动效样式（'scale' 缩放 / 'slide' 侧边滑动；默认 scale）。
  /// 对齐原版 settings.player.transitionStyle，全屏播放器切歌时
  /// 封面与歌曲信息的过渡动画。
  String get transitionStyle {
    final v = _data[_transitionStyleKey];
    if (v == 'scale' || v == 'slide') return v as String;
    return 'scale';
  }

  /// 自定义主色（ARGB 值）；null = 使用设计体系默认亮蓝。
  /// 对齐原版 appearance.themeSource=custom + customColor（hex）。
  int? get accent => _data[_accentKey] as int?;

  /// 主题色来源（对齐原版 appearance.themeSource）：
  /// - `default`：跟随系统主题色（读取系统 accent-color，失败回退默认亮蓝）；
  /// - `custom`：自定义主色（[accentColor]）；
  /// - `cover`：从当前播放曲目封面取色（实时跟随）；
  /// - `solid`：纯色中性色板（无主题色，主/次色用灰阶）。
  String get themeSource {
    final v = _data[_themeSourceKey];
    if (v == 'custom' || v == 'cover' || v == 'solid') return v as String;
    return 'default';
  }

  /// 全局着色（对齐原版 appearance.globalTint）：将主题色轻微应用到
  /// 全局界面（surface 家族向主色偏移），默认关。
  bool get globalTint => _data[_globalTintKey] as bool? ?? false;

  /// 外观风格（对齐原版 appearance.appearanceStyle）：
  /// `solid` 纯色背景 / `image` 自定义图片背景。
  String get appearanceStyle {
    final v = _data[_appearanceStyleKey];
    return v == 'image' ? 'image' : 'solid';
  }

  /// 背景图片路径（磁盘绝对路径；null = 未选择，对齐 imageBackground.src）。
  String? get backgroundImage => _data[_backgroundImageKey] as String?;

  /// 背景模糊（px，0~80，对齐 imageBackground.blur，默认 0）。
  int get backgroundBlur =>
      ((_data[_backgroundBlurKey] as num?)?.toInt() ?? 0).clamp(0, 80);

  /// 遮罩浓度（0.3~0.9，对齐 imageBackground.dim，默认 0.4）。
  double get backgroundDim =>
      ((_data[_backgroundDimKey] as num?)?.toDouble() ?? 0.4).clamp(0.3, 0.9);

  /// 背景图缩放（1~2，对齐 imageBackground.scale，默认 1.2）。
  double get backgroundScale =>
      ((_data[_backgroundScaleKey] as num?)?.toDouble() ?? 1.2).clamp(1, 2);

  /// 页面切换动效（对齐原版 appearance.routeTransition）：
  /// `none` 无 / `fade` 淡入淡出 / `slide` 滑动 / `zoom` 缩放。
  String get routeTransition {
    final v = _data[_routeTransitionKey];
    if (v == 'none' || v == 'slide' || v == 'zoom') return v as String;
    return 'fade';
  }

  /// 折叠侧边栏（对齐原版 appearance.sidebarCollapsed，默认关）。
  bool get sidebarCollapsed => _data[_sidebarCollapsedKey] as bool? ?? false;

  /// 侧边栏导航高亮动效（对齐原版 appearance.sidebarNavStyle）：
  /// `default` 静态指示条 / `animated` 滑动高亮条。
  String get sidebarNavStyle {
    final v = _data[_sidebarNavStyleKey];
    return v == 'animated' ? 'animated' : 'default';
  }

  /// 界面语言（BCP-47 字符串如 `zh-CN` / `en`；null = 跟随系统，默认）。
  /// 设置页「语言」选择，取值范围与 [AppLocalizations.supportedLocales] 对齐。
  String? get locale => _data[_localeKey] as String?;

  Color? get accentColor {
    final v = accent;
    return v == null ? null : Color(v);
  }

  /// 播放条悬浮模式（对齐原版 appearance.layoutMode=floating）：
  /// 开 = 底部居中圆角胶囊悬浮条（玻璃面板 + 阴影）；关 = 全宽停靠条。
  bool get floatingPlayerBar =>
      _data[_floatingBarKey] as bool? ?? false;

  /// 播放器内显示歌词（当前行居中高亮 + 点击跳转）。
  bool get showLyricsInPlayer => _data[_showLyricsKey] as bool? ?? true;

  /// 界面字体（内置字体族名；默认 MiSans）。
  String get fontFamily => _data[_fontFamilyKey] as String? ?? 'MiSans';

  /// 封面圆角（px；0/8/12，对齐原版 CoverList 观感，默认 10）。
  double get coverRadius {
    final v = _data[_coverRadiusKey] as num?;
    if (v == null) return 10;
    return v.toDouble().clamp(0, 16);
  }

  /// 播放器歌词字号（px，14~28，默认 18）。
  double get lyricFontSize {
    final v = _data[_lyricFontSizeKey] as num?;
    if (v == null) return 18;
    return v.toDouble().clamp(14, 28);
  }

  /// 播放器歌词行高（px，42~64，默认 52）。
  double get lyricLineHeight {
    final v = _data[_lyricLineHeightKey] as num?;
    if (v == null) return 52;
    return v.toDouble().clamp(42, 64);
  }

  /// 已唱行歌词颜色（ARGB；默认主色亮蓝，对齐原版 desktopLyric.playedColor）。
  int get lyricPlayedColor =>
      _data[_lyricPlayedColorKey] as int? ?? 0xFF4DA3FF;

  /// 未唱行歌词颜色（ARGB；默认次级前景，对齐原版 desktopLyric.unplayedColor）。
  int get lyricUnplayedColor =>
      _data[_lyricUnplayedColorKey] as int? ?? 0xFF9AA1B5;

  /// 下载根目录（默认 `~/Music/ArchoeraMusic`，设置页可改）。
  String get downloadRoot =>
      _data[_downloadRootKey] as String? ?? defaultDownloadRoot();

  /// 同时下载最大任务数（1~5，默认 3）。
  int get downloadMaxConcurrent =>
      ((_data[_downloadMaxConcurrentKey] as num?)?.toInt() ?? 3).clamp(1, 5);

  /// 下载目录分组策略（0=flat, 1=bySource, 2=byArtist，默认 bySource）。
  int get downloadSubdirStrategy =>
      ((_data[_downloadSubdirKey] as num?)?.toInt() ?? 1).clamp(0, 2);

  /// 默认下载音质档（hi-res/lossless/hq/sq/lq，默认 hq）。
  /// 非法值回退 hq；右键菜单「下载」弹窗默认选中此档。
  String get downloadQuality {
    final v = _data[_downloadQualityKey] as String?;
    return (v != null && downloadQualityLevels.contains(v)) ? v : 'hq';
  }

  /// 全局限速（bytes/sec；0 = 不限速，默认）。设置页「下载限速」可调。
  int get downloadSpeedLimit =>
      ((_data[_downloadSpeedLimitKey] as num?)?.toInt() ?? 0).clamp(0, 20 * 1024 * 1024);

  /// 文件名模板（占位符 {artist}/{title}/{album}；默认 `{artist} - {title}`）。
  /// 空串视为默认；只影响之后入队的任务。
  String get downloadFilenameTemplate {
    final v = _data[_downloadFilenameTemplateKey] as String?;
    final t = v?.trim() ?? '';
    return t.isEmpty ? '{artist} - {title}' : t;
  }

  /// 下载记录上限：失败/取消的 finished 条目超过该值淘汰最旧（10~500，默认 100）。
  int get downloadHistoryLimit =>
      ((_data[_downloadHistoryLimitKey] as num?)?.toInt() ?? 100).clamp(10, 500);

  // ── 刮削设置 ──────────────────────────────────────────────

  /// 刮削目录（非空覆盖媒体库扫描目录；默认空 = 使用扫描目录）。
  List<String> get scrapeDirs => ((_data[_scrapeDirsKey] as List?) ?? const [])
      .whereType<String>()
      .map((d) => d.trim())
      .where((d) => d.isNotEmpty)
      .toList();

  /// 数据源开关（默认全开，对齐 SPlayer-Next 刮削器默认）。
  bool get scrapeUseMusicBrainz => _data[_scrapeUseMusicBrainzKey] as bool? ?? true;
  bool get scrapeUseDeezer => _data[_scrapeUseDeezerKey] as bool? ?? true;
  bool get scrapeUseItunes => _data[_scrapeUseItunesKey] as bool? ?? true;
  bool get scrapeUseNetease => _data[_scrapeUseNeteaseKey] as bool? ?? true;
  bool get scrapeUseQQMusic => _data[_scrapeUseQQMusicKey] as bool? ?? true;
  bool get scrapeUseKugou => _data[_scrapeUseKugouKey] as bool? ?? true;
  bool get scrapeUseKuwo => _data[_scrapeUseKuwoKey] as bool? ?? true;
  bool get scrapeUseMigu => _data[_scrapeUseMiguKey] as bool? ?? true;
  bool get scrapeUseAcoustID => _data[_scrapeUseAcoustIDKey] as bool? ?? true;

  /// 关闭应用时行为（ask=每次询问 / background=后台播放 / quit=直接退出）。
  static const String defaultCloseBehavior = 'ask';

  /// 关闭应用时行为（非法值回退默认）。
  String get closeBehavior {
    final v = _data[_closeBehaviorKey];
    if (v is String && (v == 'background' || v == 'quit')) return v;
    return defaultCloseBehavior;
  }

  /// 播放音量（0~1，默认 1.0，对齐 SPlayer-Next status.volume）。
  ///
  /// 退出确认弹窗临时降半（duck）不落盘：此处始终是用户设定的音量，
  /// 弹窗关闭后 [duckVolume]/[restoreVolume] 回到该值。
  double get volume =>
      ((_data[_volumeKey] as num?)?.toDouble() ?? 1.0).clamp(0.0, 1.0);

  /// 播放条时间下方显示歌词（有歌词时替代迷你频谱；默认开）。
  bool get barLyrics => _data[_barLyricsKey] as bool? ?? true;

  /// 播放条迷你频谱（独立于播放页频谱开关；默认开）。
  bool get barSpectrum => _data[_barSpectrumKey] as bool? ?? true;

  /// 播放条高级歌词（默认开）：歌词含逐字时间轴（YRC/KRC）时，
  /// 播放条迷你歌词以卡拉OK 逐字高亮显示；关闭则始终显示普通整行歌词。
  bool get barEnhancedLyrics =>
      _data[_barEnhancedLyricsKey] as bool? ?? true;

  /// 歌词显示翻译（播放条迷你歌词与全屏播放器；默认开）。
  bool get showTranslation => _data[_showTranslationKey] as bool? ?? true;

  // ── 强迫症设置（对齐原项目 preset）────────────────────────────

  /// Fuck DJ Mode：播放时自动跳过 DJ 混音 / 口水歌（默认关）。
  bool get fuckDjMode => _data[_fuckDjModeKey] as bool? ?? false;

  /// 解锁脏话：还原歌词中「f**k」等被星号遮盖的词（默认关）。
  bool get uncensorProfanity => _data[_uncensorProfanityKey] as bool? ?? false;

  /// 隐藏歌曲列表的 VIP / 付费标签（默认关 = 显示）。
  bool get hideVipTag => _data[_hideVipTagKey] as bool? ?? false;

  /// 隐藏歌曲列表的音质角标（默认关 = 显示）。
  bool get hideQualityTag => _data[_hideQualityTagKey] as bool? ?? false;

  /// 歌曲列表显示副标题（别名，如「(Live)」；默认开）。
  bool get showSubtitle => _data[_showSubtitleKey] as bool? ?? true;

  /// 性能模式：关闭所有动效并自动关闭音频频谱（默认关）。
  ///
  /// 开 = 全局隐式动效 0 时长 + 频谱开关视为关闭（FFT 轮询/渲染全停）。
  bool get performanceMode => _data[_performanceModeKey] as bool? ?? false;

  /// 开发者模式（默认关）：隐藏的下载接口（侧边栏 / 右键菜单 /
  /// 设置-下载分类）仅在开启后显示。设置-关于内长按「版本」10 秒开启。
  /// **会话级开关**：不持久化，关闭应用后下次启动强制回到关闭状态
  /// （见 [AppPrefsNotifier.build]）。
  bool get developerMode => _data[_developerModeKey] as bool? ?? false;

  AppPrefs copyWithPassthrough(bool value) =>
      AppPrefs(data: {..._data, _passthroughKey: value});

  AppPrefs copyWithAutoPlay(bool value) =>
      AppPrefs(data: {..._data, _autoPlayOnLaunchKey: value});

  AppPrefs copyWithMemory(bool value) =>
      AppPrefs(data: {..._data, _sessionMemoryKey: value});

  AppPrefs copyWithSpectrum({bool? enable, int? barWidth}) => AppPrefs(
        data: {
          ..._data,
          _enableSpectrumKey: ?enable,
          _spectrumBarWidthKey: ?barWidth?.clamp(1, 12),
        },
      );

  AppPrefs copyWithCoverBeatScale(bool value) => AppPrefs(
        data: {..._data, _coverBeatScaleKey: value},
      );

  /// 设置封面切换动效样式（非法值不写入，getter 回退默认 scale）。
  AppPrefs copyWithTransitionStyle(String value) => AppPrefs(
        data: {
          ..._data,
          if (value == 'scale' || value == 'slide') _transitionStyleKey: value,
        },
      );

  /// 设置自定义主色（null = 恢复默认亮蓝，**移除**落盘的自定义值）。
  ///
  /// 不能用 `_accentKey: ?accent`：null-aware 元素只「不写入」，旧键仍会
  /// 经 `..._data` 残留，导致切回默认后仍是旧自定义色（无法还原）。
  AppPrefs copyWithAccent(int? accent) {
    final data = Map<String, dynamic>.of(_data);
    if (accent == null) {
      data.remove(_accentKey);
    } else {
      data[_accentKey] = accent;
    }
    return AppPrefs(data: data);
  }

  /// 设置主题色来源（非法值不写入，getter 回退默认 default）。
  AppPrefs copyWithThemeSource(String value) => AppPrefs(
        data: {
          ..._data,
          if (value == 'default' || value == 'custom' || value == 'cover' || value == 'solid')
            _themeSourceKey: value,
        },
      );

  AppPrefs copyWithGlobalTint(bool value) => AppPrefs(
        data: {
          ..._data,
          _globalTintKey: value,
        },
      );

  /// 设置外观风格（solid / image；非法值不写入）。
  AppPrefs copyWithAppearanceStyle(String value) => AppPrefs(
        data: {
          ..._data,
          if (value == 'solid' || value == 'image') _appearanceStyleKey: value,
        },
      );

  /// 设置图片背景配置（选图 / 模糊 / 遮罩 / 缩放）。
  ///
  /// [image] 为 null 时**移除**已落盘的背景图路径（清除按钮）：不能像其他
  /// 字段用 null-aware 元素——旧键会经 `..._data` 残留，导致清除后背景图
  /// 仍生效（与 copyWithAccent 相同的问题）。
  AppPrefs copyWithBackground({
    String? image,
    int? blur,
    double? dim,
    double? scale,
  }) {
    final data = Map<String, dynamic>.of(_data);
    if (image == null) {
      data.remove(_backgroundImageKey);
    } else {
      data[_backgroundImageKey] = image;
    }
    return AppPrefs(
      data: {
        ...data,
        _backgroundBlurKey: ?blur?.clamp(0, 80),
        _backgroundDimKey: ?dim?.clamp(0.3, 0.9),
        _backgroundScaleKey: ?scale?.clamp(1, 2),
      },
    );
  }

  /// 设置页面切换动效（none/fade/slide/zoom；非法值不写入）。
  AppPrefs copyWithRouteTransition(String value) => AppPrefs(
        data: {
          ..._data,
          if (value == 'none' || value == 'fade' || value == 'slide' || value == 'zoom')
            _routeTransitionKey: value,
        },
      );

  /// 设置侧边栏（折叠状态 / 导航高亮动效）。
  AppPrefs copyWithSidebar({bool? collapsed, String? navStyle}) => AppPrefs(
        data: {
          ..._data,
          _sidebarCollapsedKey: ?collapsed,
          if (navStyle == 'default' || navStyle == 'animated')
            _sidebarNavStyleKey: navStyle,
        },
      );

  /// 设置界面语言（null = 跟随系统；移除落盘值，避免残留旧语言）。
  AppPrefs copyWithLocale(String? code) {
    final data = Map<String, dynamic>.of(_data);
    if (code == null) {
      data.remove(_localeKey);
    } else {
      data[_localeKey] = code;
    }
    return AppPrefs(data: data);
  }

  AppPrefs copyWithFloatingBar(bool value) => AppPrefs(
        data: {..._data, _floatingBarKey: value},
      );

  AppPrefs copyWithLyrics({bool? showInPlayer}) => AppPrefs(
        data: {
          ..._data,
          _showLyricsKey: ?showInPlayer,
        },
      );

  AppPrefs copyWithAppearance({
    String? fontFamily,
    double? coverRadius,
  }) =>
      AppPrefs(
        data: {
          ..._data,
          _fontFamilyKey: ?fontFamily,
          _coverRadiusKey: ?coverRadius?.clamp(0, 16),
        },
      );

  AppPrefs copyWithLyricStyle({
    double? fontSize,
    double? lineHeight,
    int? playedColor,
    int? unplayedColor,
  }) =>
      AppPrefs(
        data: {
          ..._data,
          _lyricFontSizeKey: ?fontSize?.clamp(14, 28),
          _lyricLineHeightKey: ?lineHeight?.clamp(42, 64),
          _lyricPlayedColorKey: ?playedColor,
          _lyricUnplayedColorKey: ?unplayedColor,
        },
      );

  AppPrefs copyWithDownload({
    String? rootDir,
    int? maxConcurrent,
    int? subdirStrategy,
    String? quality,
    int? speedLimit,
    String? filenameTemplate,
    int? historyLimit,
  }) {
    // 非法档位 → 视为未提供（null-aware 不写入，避免覆盖旧值）
    final q =
        (quality != null && downloadQualityLevels.contains(quality))
            ? quality
            : null;
    // 空串模板 → 视为未提供（保留旧值；getter 空串回退默认）
    final tpl = (filenameTemplate != null && filenameTemplate.trim().isNotEmpty)
        ? filenameTemplate.trim()
        : null;
    return AppPrefs(
      data: {
        ..._data,
        _downloadRootKey: ?rootDir,
        _downloadMaxConcurrentKey: ?maxConcurrent?.clamp(1, 5),
        _downloadSubdirKey: ?subdirStrategy?.clamp(0, 2),
        _downloadQualityKey: ?q,
        _downloadSpeedLimitKey: ?speedLimit?.clamp(0, 20 * 1024 * 1024),
        _downloadFilenameTemplateKey: ?tpl,
        _downloadHistoryLimitKey: ?historyLimit?.clamp(10, 500),
      },
    );
  }

  /// 设置「关闭应用时」行为（ask/background/quit）。
  AppPrefs copyWithCloseBehavior(String value) => AppPrefs(
        data: {..._data, _closeBehaviorKey: value},
      );

  /// 播放音量（0~1 收敛；退出确认弹窗的 duck 不落盘，不经此方法）。
  AppPrefs copyWithVolume(double value) => AppPrefs(
        data: {..._data, _volumeKey: value.clamp(0.0, 1.0)},
      );

  /// 播放条歌词 / 播放条频谱 / 播放条高级歌词开关。
  AppPrefs copyWithBarDisplay({
    bool? barLyrics,
    bool? barSpectrum,
    bool? barEnhancedLyrics,
  }) => AppPrefs(
        data: {
          ..._data,
          _barLyricsKey: ?barLyrics,
          _barSpectrumKey: ?barSpectrum,
          _barEnhancedLyricsKey: ?barEnhancedLyrics,
        },
      );

  AppPrefs copyWithShowTranslation(bool value) => AppPrefs(
        data: {..._data, _showTranslationKey: value},
      );

  /// 刮削配置：目录（空列表 = 使用媒体库扫描目录）+ 数据源开关。
  AppPrefs copyWithScrape({
    List<String>? dirs,
    bool? useMusicBrainz,
    bool? useDeezer,
    bool? useItunes,
    bool? useNetease,
    bool? useQQMusic,
    bool? useKugou,
    bool? useKuwo,
    bool? useMigu,
    bool? useAcoustID,
  }) =>
      AppPrefs(
        data: {
          ..._data,
          _scrapeDirsKey: ?dirs,
          _scrapeUseMusicBrainzKey: ?useMusicBrainz,
          _scrapeUseDeezerKey: ?useDeezer,
          _scrapeUseItunesKey: ?useItunes,
          _scrapeUseNeteaseKey: ?useNetease,
          _scrapeUseQQMusicKey: ?useQQMusic,
          _scrapeUseKugouKey: ?useKugou,
          _scrapeUseKuwoKey: ?useKuwo,
          _scrapeUseMiguKey: ?useMigu,
          _scrapeUseAcoustIDKey: ?useAcoustID,
        },
      );

  /// 强迫症设置（对齐原项目 preset：Fuck DJ / 解锁脏话 / 标签与副标题）。
  AppPrefs copyWithPreset({
    bool? performanceMode,
    bool? fuckDjMode,
    bool? uncensorProfanity,
    bool? hideVipTag,
    bool? hideQualityTag,
    bool? showSubtitle,
  }) =>
      AppPrefs(
        data: {
          ..._data,
          _performanceModeKey: ?performanceMode,
          _fuckDjModeKey: ?fuckDjMode,
          _uncensorProfanityKey: ?uncensorProfanity,
          _hideVipTagKey: ?hideVipTag,
          _hideQualityTagKey: ?hideQualityTag,
          _showSubtitleKey: ?showSubtitle,
        },
      );

  AppPrefs copyWithDeveloperMode(bool value) => AppPrefs(
        data: {..._data, _developerModeKey: value},
      );

  /// 偏好文件路径：数据目录（`~/.local/share/ArchoeraMusic`）。
  static String get filePath => '${resolveDataDir()}/prefs.json';

  static AppPrefs load() {
    try {
      final file = File(filePath);
      if (!file.existsSync()) return AppPrefs();
      final json = jsonDecode(file.readAsStringSync());
      if (json is Map<String, dynamic>) return AppPrefs(data: json);
    } catch (_) {
      // 损坏的偏好文件：回退默认
    }
    return AppPrefs();
  }

  void save() {
    try {
      final file = File(filePath);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(_data));
    } catch (_) {
      // 持久化失败不阻塞（自用项目，偏好丢失可接受）
    }
  }
}

/// 偏好控制器（UI 读写入口；设置页切换后即时持久化）。
class AppPrefsNotifier extends Notifier<AppPrefs> {
  @override
  AppPrefs build() {
    final prefs = AppPrefs.load();
    // 开发者模式是会话级开关（不持久化）：每次启动强制关闭。
    // 会话内其它设置变更的 save() 会把整个 _data（含 developerMode）
    // 连带写盘，这里统一清掉上会话残留，保证内存与磁盘都以关闭态起步。
    if (prefs.developerMode) {
      final reset = prefs.copyWithDeveloperMode(false);
      reset.save();
      return reset;
    }
    return prefs;
  }

  /// 设置「原音质直通（不转码）」开关。
  void setPassthrough(bool value) {
    state = state.copyWithPassthrough(value);
    state.save();
  }

  /// 设置「启动时自动播放」开关。
  void setAutoPlayOnLaunch(bool value) {
    state = state.copyWithAutoPlay(value);
    state.save();
  }

  /// 设置「会话记忆」开关。
  ///
  /// 关闭记忆时**直接删除已落盘的快照**（数据层保证，不依赖调用方）：
  /// 避免残留旧现场，重新开启后从空开始，不会恢复过期数据。
  void setMemoryEnabled(bool value) {
    state = state.copyWithMemory(value);
    state.save();
    if (!value) {
      const PlaybackSessionStore().clear();
    }
  }

  /// 设置频谱可视化开关。
  void setSpectrumEnabled(bool value) {
    state = state.copyWithSpectrum(enable: value);
    state.save();
  }

  /// 设置封面跟随节拍缩放开关。
  void setCoverBeatScale(bool value) {
    state = state.copyWithCoverBeatScale(value);
    state.save();
  }

  /// 设置频谱柱宽（1~12）。
  void setSpectrumBarWidth(int value) {
    state = state.copyWithSpectrum(barWidth: value);
    state.save();
  }

  /// 设置播放音量（0~1；退出确认弹窗的 duck 不落盘）。
  void setVolume(double value) {
    state = state.copyWithVolume(value);
    state.save();
  }

  /// 设置播放条歌词 / 播放条频谱 / 播放条高级歌词显示开关。
  void setBarDisplay({
    bool? barLyrics,
    bool? barSpectrum,
    bool? barEnhancedLyrics,
  }) {
    state = state.copyWithBarDisplay(
      barLyrics: barLyrics,
      barSpectrum: barSpectrum,
      barEnhancedLyrics: barEnhancedLyrics,
    );
    state.save();
  }

  /// 设置歌词显示翻译开关。
  void setShowTranslation(bool value) {
    state = state.copyWithShowTranslation(value);
    state.save();
  }

  /// 设置封面切换动效样式（scale / slide）。
  void setTransitionStyle(String value) {
    state = state.copyWithTransitionStyle(value);
    state.save();
  }

  /// 设置自定义主色（null = 恢复默认亮蓝）。
  void setAccent(int? accent) {
    state = state.copyWithAccent(accent);
    state.save();
  }

  /// 设置主题色来源（default/custom/cover/solid）。
  void setThemeSource(String value) {
    state = state.copyWithThemeSource(value);
    state.save();
  }

  /// 设置全局着色开关。
  void setGlobalTint(bool value) {
    state = state.copyWithGlobalTint(value);
    state.save();
  }

  /// 设置外观风格（solid/image）。
  void setAppearanceStyle(String value) {
    state = state.copyWithAppearanceStyle(value);
    state.save();
  }

  /// 设置图片背景配置（选图 / 模糊 / 遮罩 / 缩放）。
  void setBackground({String? image, int? blur, double? dim, double? scale}) {
    state = state.copyWithBackground(
      image: image,
      blur: blur,
      dim: dim,
      scale: scale,
    );
    state.save();
  }

  /// 设置页面切换动效（none/fade/slide/zoom）。
  void setRouteTransition(String value) {
    state = state.copyWithRouteTransition(value);
    state.save();
  }

  /// 设置侧边栏（折叠状态 / 导航高亮动效）。
  void setSidebar({bool? collapsed, String? navStyle}) {
    state = state.copyWithSidebar(collapsed: collapsed, navStyle: navStyle);
    state.save();
  }

  /// 设置界面语言（null = 跟随系统）。
  void setLocale(String? code) {
    state = state.copyWithLocale(code);
    state.save();
  }

  /// 设置播放条悬浮模式。
  void setFloatingPlayerBar(bool value) {
    state = state.copyWithFloatingBar(value);
    state.save();
  }

  /// 设置播放器内显示歌词。
  void setShowLyricsInPlayer(bool value) {
    state = state.copyWithLyrics(showInPlayer: value);
    state.save();
  }

  /// 设置界面字体（内置字体族名）。
  void setFontFamily(String family) {
    state = state.copyWithAppearance(fontFamily: family);
    state.save();
  }

  /// 设置封面圆角（0~16px）。
  void setCoverRadius(double value) {
    state = state.copyWithAppearance(coverRadius: value);
    state.save();
  }

  /// 设置播放器歌词样式。
  void setLyricStyle({
    double? fontSize,
    double? lineHeight,
    int? playedColor,
    int? unplayedColor,
  }) {
    state = state.copyWithLyricStyle(
      fontSize: fontSize,
      lineHeight: lineHeight,
      playedColor: playedColor,
      unplayedColor: unplayedColor,
    );
    state.save();
  }

  /// 设置下载配置（根目录 / 并发数 / 分组策略 / 默认音质 / 限速 /
  /// 文件名模板 / 记录上限）。
  void setDownload({
    String? rootDir,
    int? maxConcurrent,
    int? subdirStrategy,
    String? quality,
    int? speedLimit,
    String? filenameTemplate,
    int? historyLimit,
  }) {
    state = state.copyWithDownload(
      rootDir: rootDir,
      maxConcurrent: maxConcurrent,
      subdirStrategy: subdirStrategy,
      quality: quality,
      speedLimit: speedLimit,
      filenameTemplate: filenameTemplate,
      historyLimit: historyLimit,
    );
    state.save();
  }

  /// 设置「关闭应用时」行为（ask=每次询问 / background=后台播放 / quit=直接退出）。
  void setCloseBehavior(String value) {
    state = state.copyWithCloseBehavior(value);
    state.save();
  }

  /// 设置刮削配置（目录 + 数据源开关；目录空列表 = 使用媒体库扫描目录）。
  void setScrape({
    List<String>? dirs,
    bool? useMusicBrainz,
    bool? useDeezer,
    bool? useItunes,
    bool? useNetease,
    bool? useQQMusic,
    bool? useKugou,
    bool? useKuwo,
    bool? useMigu,
    bool? useAcoustID,
  }) {
    state = state.copyWithScrape(
      dirs: dirs,
      useMusicBrainz: useMusicBrainz,
      useDeezer: useDeezer,
      useItunes: useItunes,
      useNetease: useNetease,
      useQQMusic: useQQMusic,
      useKugou: useKugou,
      useKuwo: useKuwo,
      useMigu: useMigu,
      useAcoustID: useAcoustID,
    );
    state.save();
  }

  /// 设置强迫症配置（播放过滤 / 歌词还原 / 列表标签与副标题 / 性能模式）。
  void setPreset({
    bool? performanceMode,
    bool? fuckDjMode,
    bool? uncensorProfanity,
    bool? hideVipTag,
    bool? hideQualityTag,
    bool? showSubtitle,
  }) {
    state = state.copyWithPreset(
      performanceMode: performanceMode,
      fuckDjMode: fuckDjMode,
      uncensorProfanity: uncensorProfanity,
      hideVipTag: hideVipTag,
      hideQualityTag: hideQualityTag,
      showSubtitle: showSubtitle,
    );
    state.save();
  }

  /// 设置性能模式（关闭所有动效 + 自动关闭音频频谱）。
  void setPerformanceMode(bool value) {
    state = state.copyWithPreset(performanceMode: value);
    state.save();
  }

  /// 设置开发者模式（隐藏下载接口的开关）。
  ///
  /// 会话级开关：不落盘（save() 会把整个 _data 连带写盘，若持久化，
  /// 会话内其它设置变更也会把 developerMode 一起留下）。关闭应用后
  /// 下次启动自动回到关闭状态（见 build() 的强制重置）。
  void setDeveloperMode(bool value) {
    state = state.copyWithDeveloperMode(value);
  }
}

final appPrefsProvider =
    NotifierProvider<AppPrefsNotifier, AppPrefs>(AppPrefsNotifier.new);
