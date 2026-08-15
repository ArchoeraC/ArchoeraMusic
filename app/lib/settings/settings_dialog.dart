/// 全局设置弹窗（对齐原项目 SettingsDialog：左侧分类菜单 + 右侧内容区）。
///
/// 各分类内容组件拆在 [settings_sections.dart]（AppearanceSection /
/// PlaybackSection / LyricsSection / PresetSection / DownloadSection /
/// ScrapeSection / StorageSection / AboutSection / DeveloperSection），
/// 本文件保留弹窗骨架：分类导航 / 搜索 / 开发者长按开启逻辑。
library;

import 'dart:async' show Timer;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import '../stores/app_prefs.dart';
import '../theme/app_theme.dart';
import '../widgets/common/anim.dart';
import '../widgets/common/glass_surface.dart';
import '../widgets/common/toast.dart';
import 'cache_section.dart';
import 'history_section.dart';
import 'security_section.dart';
import 'settings_categories.dart';
import 'settings_sections.dart';
import 'streaming_server_list.dart';

export 'settings_categories.dart';

void showSettingsDialog(BuildContext context, {SettingsCategory? category}) {
  showDialog<void>(
    context: context,
    // 全局变暗遮罩（统一所有弹窗样式）
    barrierColor: Colors.black.withValues(alpha: 0.5),
    builder: (_) => SettingsDialog(initialCategory: category),
  );
}

class _SearchEntry {
  const _SearchEntry(this.category, this.title, this.subtitle, this.icon);
  final SettingsCategory category;
  final String title;
  final String subtitle;
  final IconData icon;
}

class SettingsDialog extends ConsumerStatefulWidget {
  const SettingsDialog({super.key, this.initialCategory});

  /// 打开时选中的分类（默认 appearance）。
  final SettingsCategory? initialCategory;

  @override
  ConsumerState<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends ConsumerState<SettingsDialog> {
  late SettingsCategory _category =
      widget.initialCategory ?? SettingsCategory.appearance;
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';
  String _version = '';

  // ── 开发者模式：长按「版本」10 秒开启（按住进度反馈）──
  Timer? _devHoldTimer;
  bool _devHolding = false;
  double _devHoldProgress = 0;

  /// 设置分类导航锚点（animated 滑动指示条测量用；key 为分类）。
  final Map<SettingsCategory, GlobalKey> _catKeys = {};

  /// 分类列表容器锚点（指示条坐标参照系）。
  final GlobalKey _catHostKey = GlobalKey();

  /// 滑动指示条当前位置（相对分类列表容器；与侧边栏 animated 模式同语义）。
  double _catIndicatorLeft = 0;
  double _catIndicatorTop = 0;
  double _catIndicatorHeight = 0;
  bool _catIndicatorReady = false;

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    try {
      final data = await rootBundle.loadString('pubspec.yaml');
      final match = RegExp(
        r'^version:\s*([0-9][^\s#]*)(?:\s*#.*)?$',
        multiLine: true,
      ).firstMatch(data);
      var v = match?.group(1) ?? '';
      // Dart 版本号中 '-' 预发布、'+' 构建号 → 显示时转回 '.' 分段（如 0.8.3.pre.2.rev.3）
      v = v.replaceAll('-', '.').replaceAll('+', '.');
      if (mounted && v.isNotEmpty) setState(() => _version = v);
    } catch (_) {}
  }

  // ── 开发者模式：长按「版本」10 秒开启 ──────────────────────────
  //
  // 鼠标与触摸屏通用：Listener 的 pointer down/up 对两类指针一视同仁
  // （鼠标按住左键不松 / 手指长按均可触发）；MouseRegion 悬浮 1s 后
  // 弹提示，进度条实时反馈剩余时间。

  void _startDevHold() {
    if (_devHolding) return;
    setState(() {
      _devHolding = true;
      _devHoldProgress = 0;
    });
    _devHoldTimer?.cancel();
    final sw = Stopwatch()..start();
    _devHoldTimer = Timer.periodic(const Duration(milliseconds: 100), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      final p = sw.elapsedMilliseconds / 10000;
      if (p >= 1) {
        t.cancel();
        _completeDevHold();
      } else {
        setState(() => _devHoldProgress = p);
      }
    });
  }

  void _cancelDevHold() {
    _devHoldTimer?.cancel();
    _devHoldTimer = null;
    if (mounted && _devHolding) {
      setState(() {
        _devHolding = false;
        _devHoldProgress = 0;
      });
    }
  }

  void _completeDevHold() {
    _devHoldTimer?.cancel();
    _devHoldTimer = null;
    if (mounted) {
      setState(() {
        _devHolding = false;
        _devHoldProgress = 0;
      });
    }
    final l10n = context.l10n;
    final notifier = ref.read(appPrefsProvider.notifier);
    if (!ref.read(appPrefsProvider).developerMode) {
      notifier.setDeveloperMode(true);
    }
    toast(
      l10n.settingsDeveloperEnabled,
      type: ToastType.success,
      duration: const Duration(milliseconds: 1600),
    );
    if (mounted) setState(() => _category = SettingsCategory.developer);
  }

  List<_SearchEntry> _buildSearchIndex(AppLocalizations l10n) {
    return [
      _SearchEntry(
        SettingsCategory.appearance,
        l10n.settingsThemeMode,
        l10n.settingsThemeModeDesc,
        Icons.dark_mode_outlined,
      ),
      _SearchEntry(
        SettingsCategory.appearance,
        l10n.settingsThemeSource,
        l10n.settingsSearchThemeSourceSubtitle,
        Icons.color_lens_outlined,
      ),
      _SearchEntry(
        SettingsCategory.appearance,
        l10n.settingsGlobalTint,
        l10n.settingsSearchGlobalTintSubtitle,
        Icons.tonality_outlined,
      ),
      _SearchEntry(
        SettingsCategory.appearance,
        l10n.settingsAppearanceStyle,
        l10n.settingsSearchBackgroundSubtitle,
        Icons.image_outlined,
      ),
      _SearchEntry(
        SettingsCategory.appearance,
        l10n.settingsRouteTransition,
        l10n.settingsSearchRouteTransitionSubtitle,
        Icons.animation_outlined,
      ),
      _SearchEntry(
        SettingsCategory.appearance,
        l10n.settingsSidebarCollapsed,
        l10n.settingsSearchSidebarSubtitle,
        Icons.menu_open,
      ),
      _SearchEntry(
        SettingsCategory.appearance,
        l10n.settingsFloatingBar,
        l10n.settingsSearchFloatingBarSubtitle,
        Icons.rounded_corner,
      ),
      _SearchEntry(
        SettingsCategory.appearance,
        l10n.settingsSectionFont,
        l10n.settingsSearchFontSubtitle,
        Icons.font_download_outlined,
      ),
      _SearchEntry(
        SettingsCategory.appearance,
        l10n.settingsLanguageTitle,
        l10n.settingsSearchLanguageSubtitle,
        Icons.language_outlined,
      ),
      _SearchEntry(
        SettingsCategory.appearance,
        l10n.settingsCoverRadius,
        l10n.settingsSearchCoverRadiusSubtitle,
        Icons.crop_square,
      ),
      _SearchEntry(
        SettingsCategory.appearance,
        l10n.settingsWeather,
        l10n.settingsSearchWeatherSubtitle,
        Icons.wb_sunny_outlined,
      ),
      _SearchEntry(
        SettingsCategory.appearance,
        l10n.settingsPassthrough,
        l10n.settingsSearchPassthroughSubtitle,
        Icons.high_quality_outlined,
      ),
      _SearchEntry(
        SettingsCategory.playback,
        l10n.settingsSessionMemory,
        l10n.settingsSearchSessionMemorySubtitle,
        Icons.history,
      ),
      _SearchEntry(
        SettingsCategory.playback,
        l10n.settingsAutoPlay,
        l10n.settingsSearchAutoPlaySubtitle,
        Icons.play_circle_outline,
      ),
      _SearchEntry(
        SettingsCategory.playback,
        l10n.settingsSpectrum,
        l10n.settingsSearchSpectrumSubtitle,
        Icons.graphic_eq,
      ),
      _SearchEntry(
        SettingsCategory.playback,
        l10n.settingsSpectrumBarWidth,
        l10n.settingsSearchSpectrumWidthSubtitle,
        Icons.view_column_outlined,
      ),
      _SearchEntry(
        SettingsCategory.playback,
        l10n.settingsTransitionStyle,
        l10n.settingsTransitionStyleDesc,
        Icons.animation_outlined,
      ),
      _SearchEntry(
        SettingsCategory.lyrics,
        l10n.settingsPlayerLyrics,
        l10n.settingsSearchPlayerLyricsSubtitle,
        Icons.lyrics_outlined,
      ),
      _SearchEntry(
        SettingsCategory.lyrics,
        l10n.settingsBarLyrics,
        l10n.settingsBarLyricsOn,
        Icons.menu_book_outlined,
      ),
      _SearchEntry(
        SettingsCategory.lyrics,
        l10n.settingsBarEnhancedLyrics,
        l10n.settingsBarEnhancedLyricsOn,
        Icons.mic_external_on_outlined,
      ),
      _SearchEntry(
        SettingsCategory.lyrics,
        l10n.settingsLyricFontSize,
        l10n.settingsSearchLyricFontSizeSubtitle,
        Icons.format_size,
      ),
      _SearchEntry(
        SettingsCategory.lyrics,
        l10n.settingsLyricLineHeight,
        l10n.settingsSearchLyricLineHeightSubtitle,
        Icons.line_weight,
      ),
      _SearchEntry(
        SettingsCategory.lyrics,
        l10n.settingsSearchColorTitle,
        l10n.settingsSearchColorSubtitle,
        Icons.palette_outlined,
      ),
      _SearchEntry(
        SettingsCategory.lyrics,
        l10n.settingsSearchDesktopLyricsTitle,
        l10n.settingsSearchDesktopLyricsSubtitle,
        Icons.desktop_windows_outlined,
      ),
      _SearchEntry(
        SettingsCategory.preset,
        l10n.settingsEnergySaving,
        l10n.settingsSearchEnergySavingSubtitle,
        Icons.energy_savings_leaf_outlined,
      ),
      _SearchEntry(
        SettingsCategory.preset,
        l10n.settingsPerformanceMode,
        l10n.settingsPerformanceModeOn,
        Icons.bolt_outlined,
      ),
      _SearchEntry(
        SettingsCategory.preset,
        l10n.settingsSearchDjModeTitle,
        l10n.settingsDjModeOn,
        Icons.auto_fix_high_outlined,
      ),
      _SearchEntry(
        SettingsCategory.preset,
        l10n.settingsUncensor,
        l10n.settingsSearchUncensorSubtitle,
        Icons.auto_fix_normal_outlined,
      ),
      _SearchEntry(
        SettingsCategory.preset,
        l10n.settingsHideVip,
        l10n.settingsSearchHideVipSubtitle,
        Icons.workspace_premium_outlined,
      ),
      _SearchEntry(
        SettingsCategory.preset,
        l10n.settingsHideQuality,
        l10n.settingsSearchHideQualitySubtitle,
        Icons.high_quality_outlined,
      ),
      _SearchEntry(
        SettingsCategory.preset,
        l10n.settingsShowSubtitle,
        l10n.settingsSearchSubtitleSubtitle,
        Icons.subtitles_outlined,
      ),
      _SearchEntry(
        SettingsCategory.download,
        l10n.settingsDataDir,
        l10n.settingsSearchDownloadDirSubtitle,
        Icons.folder_outlined,
      ),
      _SearchEntry(
        SettingsCategory.download,
        l10n.settingsSearchFilenameTitle,
        l10n.settingsSearchFilenameSubtitle,
        Icons.text_fields_outlined,
      ),
      _SearchEntry(
        SettingsCategory.download,
        l10n.settingsDownloadConcurrent,
        l10n.settingsSearchConcurrentSubtitle,
        Icons.speed_outlined,
      ),
      _SearchEntry(
        SettingsCategory.download,
        l10n.settingsDownloadSpeedLimit,
        l10n.settingsSearchSpeedLimitSubtitle,
        Icons.speed_outlined,
      ),
      _SearchEntry(
        SettingsCategory.download,
        l10n.settingsDownloadQuality,
        l10n.settingsSearchQualitySubtitle,
        Icons.high_quality_outlined,
      ),
      _SearchEntry(
        SettingsCategory.download,
        l10n.settingsDownloadGrouping,
        l10n.settingsSearchGroupingSubtitle,
        Icons.folder_copy_outlined,
      ),
      _SearchEntry(
        SettingsCategory.download,
        l10n.settingsDownloadHistoryLimit,
        l10n.settingsSearchHistoryLimitSubtitle,
        Icons.history_outlined,
      ),
      _SearchEntry(
        SettingsCategory.storage,
        l10n.settingsDataDir,
        l10n.settingsSearchStorageSubtitle,
        Icons.folder_outlined,
      ),
      _SearchEntry(
        SettingsCategory.storage,
        l10n.settingsSectionCache,
        l10n.settingsCacheNote,
        Icons.cleaning_services_outlined,
      ),
      _SearchEntry(
        SettingsCategory.storage,
        l10n.settingsSongCache,
        l10n.settingsSearchSongCacheSubtitle,
        Icons.offline_pin_outlined,
      ),
      _SearchEntry(
        SettingsCategory.storage,
        l10n.settingsSecuritySection,
        l10n.settingsSecurityNote,
        Icons.delete_forever_outlined,
      ),
      _SearchEntry(
        SettingsCategory.scrape,
        l10n.settingsCatScrape,
        l10n.settingsScrapeSubtitle,
        Icons.auto_fix_high,
      ),
      _SearchEntry(
        SettingsCategory.mediaSource,
        l10n.settingsCatMediaSource,
        l10n.settingsMediaSourceSubtitle,
        Icons.dns_outlined,
      ),
      _SearchEntry(
        SettingsCategory.about,
        l10n.settingsVersion,
        l10n.settingsSearchAboutSubtitle,
        Icons.info_outline,
      ),
      // 开发者组件（仅开发者模式开启时可见，见 _buildSearchResults 过滤）
      _SearchEntry(
        SettingsCategory.developer,
        l10n.settingsDevFpsMonitor,
        l10n.settingsDevFpsMonitorDesc,
        Icons.monitor_heart_outlined,
      ),
    ];
  }

  /// 测量选中分类在列表容器中的位置，驱动滑动指示条
  /// （对齐侧边栏 animated 模式；分类切换后经 postFrameCallback 调用）。
  void _updateCategoryIndicator() {
    if (ref.read(appPrefsProvider).sidebarNavStyle != 'animated') return;
    final hostCtx = _catHostKey.currentContext;
    final itemCtx = _catKeys[_category]?.currentContext;
    if (hostCtx == null || itemCtx == null || !itemCtx.mounted) return;
    final hostBox = hostCtx.findRenderObject() as RenderBox?;
    final itemBox = itemCtx.findRenderObject() as RenderBox?;
    if (hostBox == null || itemBox == null) return;
    final pos = itemBox.localToGlobal(Offset.zero, ancestor: hostBox);
    final left = pos.dx;
    final top = pos.dy;
    final height = itemBox.size.height;
    if (!_catIndicatorReady ||
        left != _catIndicatorLeft ||
        top != _catIndicatorTop ||
        height != _catIndicatorHeight) {
      setState(() {
        _catIndicatorLeft = left;
        _catIndicatorTop = top;
        _catIndicatorHeight = height;
        _catIndicatorReady = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;
    final window = MediaQuery.sizeOf(context);
    // 设置分类导航与侧边栏使用同样的高亮动效（对齐原版 SettingsMenu：
    // nav-style 跟随 appearance.sidebarNavStyle）
    final animated = ref.watch(appPrefsProvider).sidebarNavStyle == 'animated';
    // 开发者模式：下载分类 / 开发者分类仅在开启后显示
    final devMode = ref.watch(appPrefsProvider).developerMode;
    // 布局完成后测量选中分类位置（animated 滑动指示条）
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _updateCategoryIndicator(),
    );
    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.dialog),
        side: BorderSide(color: scheme.outline.withValues(alpha: 0.5)),
      ),
      // 裁剪整个弹窗画布到 shape 圆角（Dialog 默认 Clip.none）
      clipBehavior: Clip.antiAlias,
      // 图片风格下为毛玻璃（blur(16)），背景图不再清晰透出
      child: GlassDialogSurface(
        radius: BorderRadius.circular(AppRadius.dialog),
        color: scheme.surfaceContainerHighest,
        child: SizedBox(
          width: (window.width * 0.8).clamp(640.0, 960.0),
          height: (window.height * 0.84).clamp(480.0, 660.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 210,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 20, 12, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              l10n.settingsTitle,
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w700,
                                color: scheme.onSurface,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: l10n.commonClose,
                            iconSize: 18,
                            visualDensity: VisualDensity.compact,
                            onPressed: () => Navigator.of(context).pop(),
                            icon: Icon(
                              Icons.close,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        l10n.appName,
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                        ),
                      ),
                      const SizedBox(height: 18),
                      Expanded(
                        child: Stack(
                          key: _catHostKey,
                          children: [
                            ListView(
                              padding: EdgeInsets.zero,
                              children: [
                                for (final cat in SettingsCategory.values)
                                  if (cat.visible(devMode))
                                    _buildCategoryItem(
                                      scheme,
                                      cat,
                                      l10n,
                                      animated,
                                    ),
                              ],
                            ),
                            // 滑动高亮指示条（对齐侧边栏 animated 模式：
                            // left 跟随选中项左缘，top/height 上下各内缩 10px）
                            if (animated && _catIndicatorReady)
                              AnimatedPositioned(
                                duration: animDuration(
                                  context,
                                  const Duration(milliseconds: 250),
                                ),
                                curve: Curves.easeOut,
                                left: _catIndicatorLeft,
                                top: _catIndicatorTop + 10,
                                height: _catIndicatorHeight - 20,
                                width: 3,
                                child: IgnorePointer(
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: scheme.primary,
                                      borderRadius: BorderRadius.circular(2),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
                  child: _buildContent(scheme, l10n),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCategoryItem(
    ColorScheme scheme,
    SettingsCategory cat,
    AppLocalizations l10n,
    bool animated,
  ) {
    final selected = _category == cat;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: AnimatedContainer(
        // 位置锚点：animated 滑动指示条据此定位（挂在背景容器上，
        // 使 top+10 / height-20 与静态模式完全对齐）
        key: _catKeys[cat] ??= GlobalKey(),
        duration: animDuration(context, const Duration(milliseconds: 150)),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          color: selected
              ? scheme.primary.withValues(alpha: 0.10)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            hoverColor: selected
                ? Colors.transparent
                : scheme.onSurface.withValues(alpha: 0.05),
            onTap: () => setState(() => _category = cat),
            child: SizedBox(
              height: 40,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // 静态指示条（对齐 SMenu default；animated 模式交给容器级滑动条）
                  Positioned(
                    left: 0,
                    top: 10,
                    bottom: 10,
                    child: AnimatedContainer(
                      duration: animDuration(
                        context,
                        const Duration(milliseconds: 150),
                      ),
                      width: 3,
                      decoration: BoxDecoration(
                        color: !animated && selected
                            ? scheme.primary
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 16),
                    child: Row(
                      children: [
                        Icon(
                          cat.icon,
                          size: 18,
                          color: selected ? scheme.primary : scheme.onSurface,
                        ),
                        const SizedBox(width: 12),
                        Text(
                          cat.label(l10n),
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: selected
                                ? FontWeight.w600
                                : FontWeight.w400,
                            color: selected ? scheme.primary : scheme.onSurface,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(ColorScheme scheme, AppLocalizations l10n) {
    final searching = _query.trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _searchField(scheme, l10n),
        const SizedBox(height: 14),
        if (searching)
          Expanded(child: _buildSearchResults(scheme, l10n))
        else ...[
          Text(
            _category.label(l10n),
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            _category.subtitle(l10n),
            style: TextStyle(
              fontSize: 12,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 18),
          Expanded(
            child: SingleChildScrollView(
              child: switch (_category) {
                SettingsCategory.appearance => const AppearanceSection(),
                SettingsCategory.playback => const PlaybackSection(),
                SettingsCategory.lyrics => const LyricsSection(),
                SettingsCategory.preset => const PresetSection(),
                SettingsCategory.download => const DownloadSection(),
                SettingsCategory.storage => const Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    CacheSection(),
                    HistorySection(),
                    StorageSection(),
                    SecuritySection(),
                  ],
                ),
                SettingsCategory.scrape => const ScrapeSection(),
                SettingsCategory.mediaSource => StreamingServerList(),
                SettingsCategory.about => AboutSection(
                  version: _version,
                  devHolding: _devHolding,
                  devHoldProgress: _devHoldProgress,
                  onDevHoldStart: _startDevHold,
                  onDevHoldCancel: _cancelDevHold,
                ),
                SettingsCategory.developer => DeveloperSection(
                  onDeveloperDisabled: () {
                    // 关闭后分类不可达 → 退回关于页
                    if (mounted) {
                      setState(() => _category = SettingsCategory.about);
                    }
                  },
                ),
              },
            ),
          ),
        ],
      ],
    );
  }

  Widget _searchField(ColorScheme scheme, AppLocalizations l10n) {
    return TextField(
      controller: _searchCtrl,
      onChanged: (v) => setState(() => _query = v),
      style: const TextStyle(fontSize: 13),
      decoration: InputDecoration(
        hintText: l10n.settingsSearchHint,
        prefixIcon: const Icon(Icons.search, size: 18),
        suffixIcon: _query.isEmpty
            ? null
            : IconButton(
                tooltip: l10n.commonClear,
                iconSize: 16,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close),
                onPressed: () {
                  _searchCtrl.clear();
                  setState(() => _query = '');
                },
              ),
        isDense: true,
      ),
    );
  }

  Widget _buildSearchResults(ColorScheme scheme, AppLocalizations l10n) {
    final q = _query.trim().toLowerCase();
    // 隐藏分类（下载/开发者）不进搜索结果，避免泄露隐藏接口
    final devMode = ref.watch(appPrefsProvider).developerMode;
    final index = _buildSearchIndex(
      l10n,
    ).where((e) => e.category.visible(devMode)).toList();
    final matches = index.where((e) => _searchMatch(e, q, l10n)).toList();
    if (matches.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.search_off,
              size: 36,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.settingsSearchNoResult(_query),
              style: TextStyle(
                fontSize: 13,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      );
    }
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.settingsSearchMatchCount(matches.length),
            style: TextStyle(
              fontSize: 11,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(height: 8),
          for (final cat in SettingsCategory.values)
            if (cat.visible(devMode) &&
                matches.any((e) => e.category == cat)) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Icon(cat.icon, size: 13, color: scheme.primary),
                    const SizedBox(width: 6),
                    Text(
                      cat.label(l10n),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: scheme.primary,
                      ),
                    ),
                  ],
                ),
              ),
              for (final e in matches.where((e) => e.category == cat))
                _searchResultTile(scheme, e, q),
            ],
        ],
      ),
    );
  }

  bool _searchMatch(_SearchEntry e, String q, AppLocalizations l10n) =>
      e.title.toLowerCase().contains(q) ||
      e.subtitle.toLowerCase().contains(q) ||
      e.category.label(l10n).toLowerCase().contains(q);

  Widget _searchResultTile(ColorScheme scheme, _SearchEntry e, String q) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: scheme.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          hoverColor: scheme.onSurface.withValues(alpha: 0.05),
          onTap: () {
            setState(() {
              _category = e.category;
              _searchCtrl.clear();
              _query = '';
            });
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(e.icon, size: 17, color: scheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text.rich(
                        TextSpan(
                          children: _highlight(e.title, q, scheme),
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: scheme.onSurface,
                          ),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        e.subtitle,
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right,
                  size: 16,
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<InlineSpan> _highlight(String text, String q, ColorScheme scheme) {
    final lower = text.toLowerCase();
    final spans = <InlineSpan>[];
    var start = 0;
    while (true) {
      final idx = lower.indexOf(q, start);
      if (idx < 0) {
        spans.add(TextSpan(text: text.substring(start)));
        break;
      }
      if (idx > start) spans.add(TextSpan(text: text.substring(start, idx)));
      spans.add(
        TextSpan(
          text: text.substring(idx, idx + q.length),
          style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w700),
        ),
      );
      start = idx + q.length;
    }
    return spans;
  }
}
