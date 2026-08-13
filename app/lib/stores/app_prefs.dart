import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/playback/playback_session.dart';
import 'data_dir.dart';
import 'prefs_app.dart';
import 'prefs_appearance.dart';
import 'prefs_download.dart';
import 'prefs_lyrics.dart';
import 'prefs_player.dart';
import 'prefs_power.dart';
import 'prefs_preset.dart';
import 'prefs_scrape.dart';

export 'prefs_app.dart';
export 'prefs_appearance.dart';
export 'prefs_download.dart';
export 'prefs_lyrics.dart';
export 'prefs_player.dart';
export 'prefs_power.dart';
export 'prefs_preset.dart';
export 'prefs_scrape.dart';

/// 应用偏好（轻量 JSON 文件持久化，存数据目录 `prefs.json`）。
///
/// 架构决策：Dart 只持轻量 UI 态/偏好（队列/历史/UI 偏好存 Dart 本地）；
/// 此处为 UI 偏好的最小实现，避免为单个开关引入 Hive/drift 依赖。
///
/// 字段按域拆在 `prefs_*.dart` 扩展文件中（PlayerPrefs / AppearancePrefs /
/// LyricsPrefs / DownloadPrefs / AppLevelPrefs / PowerPrefs / ScrapePrefs /
/// PresetPrefs），本文件统一 re-export 保持 `prefs.xxx` 调用点不变。
class AppPrefs {
  AppPrefs({Map<String, dynamic>? initialData}) : data = initialData ?? {};

  /// 偏好原始数据（各域扩展通过 [data] 读写对应键）。
  final Map<String, dynamic> data;

  /// 偏好文件路径：数据目录（`~/.local/share/ArchoeraMusic`）。
  static String get filePath => '${resolveDataDir()}/prefs.json';

  static AppPrefs load() {
    try {
      final file = File(filePath);
      if (!file.existsSync()) return AppPrefs();
      final json = jsonDecode(file.readAsStringSync());
      if (json is Map<String, dynamic>) return AppPrefs(initialData: json);
    } catch (_) {
      // 损坏的偏好文件：回退默认
    }
    return AppPrefs();
  }

  void save() {
    try {
      final file = File(filePath);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(data));
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
    // 会话内其它设置变更的 save() 会把整个 data（含 developerMode）
    // 连带写盘，这里统一清掉上会话残留，保证内存与磁盘都以关闭态起步。
    // 开发者组件开关（FPS 监控等）同理会话级、默认全关，一并重置。
    if (prefs.developerMode || prefs.devFpsMonitor) {
      final reset = prefs
          .copyWithDeveloperMode(false)
          .copyWithDevFpsMonitor(false);
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

  /// 设置顶栏微型天气组件开关（默认关；开启后才可能发起定位/天气请求）。
  void setWeatherEnabled(bool value) {
    state = state.copyWithWeather(enabled: value);
    state.save();
  }

  /// 设置天气「自动定位」（按 IP；默认关，隐私优先）。
  void setWeatherAutoLocate(bool value) {
    state = state.copyWithWeather(autoLocate: value);
    state.save();
  }

  /// 设置手动城市（null = 清除；填写后不再进行 IP 定位）。
  void setWeatherCity(String? city) {
    state = state.copyWithWeather(city: city);
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

  /// 设置设备指纹（首次启动生成后不变；持久化到 prefs）。
  ///
  /// 注入路径：download_controller init 引擎后 `setDownloaderIdentity` →
  /// Rust `archoera_downloader_set_identity`。清除数据时一并删除即可重置。
  void setDownloaderIdentity(String identityJson) {
    state = state.copyWithDownloaderIdentity(identityJson);
    state.save();
  }

  /// 动态设备指纹开关（默认关闭）：开启 = 回退旧版「每次启动随机」动态值，
  /// 关闭 = 持久化指纹。切换后由调用方调 `syncSessions()` 立即重注入/清除。
  void setDownloadDynamicFingerprint(bool value) {
    state = state.copyWithDownloadDynamicFingerprint(value);
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

  /// 节能模式：降低频谱取帧频率以节省 CPU（默认关，见 [AppPrefs.energySavingMode]）。
  void setEnergySaving(bool value) {
    state = state.copyWithPreset(energySavingMode: value);
    state.save();
  }

  /// 歌曲磁盘缓存开关（默认开，见 [AppPrefs.songCacheEnabled]）。
  void setSongCacheEnabled(bool value) {
    state = state.copyWithPreset(songCacheEnabled: value);
    state.save();
  }

  /// 歌曲磁盘缓存上限（MiB，见 [AppPrefs.songCacheLimitMiB]）。
  void setSongCacheLimitMiB(int value) {
    state = state.copyWithPreset(
      songCacheLimitMiB: value.clamp(
        songCacheLimitMinMiB,
        songCacheLimitMaxMiB,
      ),
    );
    state.save();
  }

  /// 歌词缓存上限（MiB）：传 null 表示不修改；传 0 表示无上限
  /// （[AppPrefs.lyricCacheLimitMiB] 返回 null）；其余按上下限收敛。
  void setLyricCacheLimitMiB(int? value) {
    if (value == null || value <= 0) {
      state = state.copyWithPreset(lyricCacheLimitMiB: 0); // 无上限
    } else {
      state = state.copyWithPreset(
        lyricCacheLimitMiB: value.clamp(
          lyricCacheLimitMinMiB,
          lyricCacheLimitMaxMiB,
        ),
      );
    }
    state.save();
  }

  /// 封面图片缓存上限（MiB）：语义同 [setLyricCacheLimitMiB]。
  void setImageCacheLimitMiB(int? value) {
    if (value == null || value <= 0) {
      state = state.copyWithPreset(imageCacheLimitMiB: 0); // 无上限
    } else {
      state = state.copyWithPreset(
        imageCacheLimitMiB: value.clamp(
          imageCacheLimitMinMiB,
          imageCacheLimitMaxMiB,
        ),
      );
    }
    state.save();
  }

  /// 设置开发者模式（隐藏下载接口的开关）。
  ///
  /// 会话级开关：不落盘（save() 会把整个 data 连带写盘，若持久化，
  /// 会话内其它设置变更也会把 developerMode 一起留下）。关闭应用后
  /// 下次启动自动回到关闭状态（见 build() 的强制重置）。
  ///
  /// **关闭开发者模式 = 全量关闭原则**：所有开发者组件（FPS 监控等）
  /// 一并复位，避免残留单独开启的组件。
  void setDeveloperMode(bool value) {
    var next = state.copyWithDeveloperMode(value);
    if (!value && next.devFpsMonitor) {
      next = next.copyWithDevFpsMonitor(false);
    }
    state = next;
  }

  /// 开发者「FPS/内存监控浮层」开关（会话级，默认关；仅在开发者模式
  /// 开启时生效——[FpsMonitorHost] 双重门控）。
  void setDevFpsMonitor(bool value) {
    state = state.copyWithDevFpsMonitor(value);
  }

  /// 设置节能模式总开关。
  void setPowerSaver(bool value) {
    state = state.copyWithPower(saver: value);
    state.save();
  }

  /// 设置「禁用系统休眠」。
  void setSuppressSleep(bool value) {
    state = state.copyWithPower(suppressSleep: value);
    state.save();
  }
}

final appPrefsProvider = NotifierProvider<AppPrefsNotifier, AppPrefs>(
  AppPrefsNotifier.new,
);
