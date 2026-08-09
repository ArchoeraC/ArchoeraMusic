import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' show Color;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../playback/playback_session.dart';
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
  static const _spectrumBarWidthKey = 'player.spectrumBarWidth';
  static const _accentKey = 'appearance.accent';
  static const _accentSystemKey = 'appearance.accentSystem';
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

  // ── 强迫症设置（对齐原项目 preset：Fuck DJ / 解锁脏话 / 标签与副标题）──
  static const _fuckDjModeKey = 'preset.fuckDjMode';
  static const _uncensorProfanityKey = 'preset.uncensorProfanity';
  static const _hideVipTagKey = 'preset.hideVipTag';
  static const _hideQualityTagKey = 'preset.hideQualityTag';
  static const _showSubtitleKey = 'preset.showSubtitle';

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

  int get spectrumBarWidth {
    final v = _data[_spectrumBarWidthKey] as num?;
    if (v == null) return defaultSpectrumBarWidth;
    return v.round().clamp(1, 12);
  }

  /// 自定义主色（ARGB 值）；null = 使用设计体系默认亮蓝。
  /// 对齐原版 appearance.themeSource=custom + customColor（hex）。
  int? get accent => _data[_accentKey] as int?;

  /// 跟随系统主题色（Linux/GNOME 读取 `org.gnome.desktop.interface`
  /// accent-color；读取失败或非 Linux 回退 [accent]；默认关）。
  bool get accentSystem =>
      _data[_accentSystemKey] as bool? ?? false;

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

  /// 关闭应用时行为（ask=每次询问 / background=后台播放 / quit=直接退出）。
  static const String defaultCloseBehavior = 'ask';

  /// 关闭应用时行为（非法值回退默认）。
  String get closeBehavior {
    final v = _data[_closeBehaviorKey];
    if (v is String && (v == 'background' || v == 'quit')) return v;
    return defaultCloseBehavior;
  }

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

  AppPrefs copyWithAccentSystem(bool value) => AppPrefs(
        data: {
          ..._data,
          _accentSystemKey: value,
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

  /// 强迫症设置（对齐原项目 preset：Fuck DJ / 解锁脏话 / 标签与副标题）。
  AppPrefs copyWithPreset({
    bool? fuckDjMode,
    bool? uncensorProfanity,
    bool? hideVipTag,
    bool? hideQualityTag,
    bool? showSubtitle,
  }) =>
      AppPrefs(
        data: {
          ..._data,
          _fuckDjModeKey: ?fuckDjMode,
          _uncensorProfanityKey: ?uncensorProfanity,
          _hideVipTagKey: ?hideVipTag,
          _hideQualityTagKey: ?hideQualityTag,
          _showSubtitleKey: ?showSubtitle,
        },
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
  AppPrefs build() => AppPrefs.load();

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

  /// 设置频谱柱宽（1~12）。
  void setSpectrumBarWidth(int value) {
    state = state.copyWithSpectrum(barWidth: value);
    state.save();
  }

  /// 设置自定义主色（null = 恢复默认亮蓝）。
  void setAccent(int? accent) {
    state = state.copyWithAccent(accent);
    state.save();
  }

  /// 设置「跟随系统主题色」开关（开启后主色取系统主题色，
  /// 读取失败时回退当前自定义色）。
  void setAccentSystem(bool value) {
    state = state.copyWithAccentSystem(value);
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

  /// 设置强迫症配置（播放过滤 / 歌词还原 / 列表标签与副标题）。
  void setPreset({
    bool? fuckDjMode,
    bool? uncensorProfanity,
    bool? hideVipTag,
    bool? hideQualityTag,
    bool? showSubtitle,
  }) {
    state = state.copyWithPreset(
      fuckDjMode: fuckDjMode,
      uncensorProfanity: uncensorProfanity,
      hideVipTag: hideVipTag,
      hideQualityTag: hideQualityTag,
      showSubtitle: showSubtitle,
    );
    state.save();
  }
}

final appPrefsProvider =
    NotifierProvider<AppPrefsNotifier, AppPrefs>(AppPrefsNotifier.new);
