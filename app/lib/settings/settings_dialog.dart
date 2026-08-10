/// 全局设置弹窗（对齐原项目 SettingsDialog：左侧分类菜单 + 右侧内容区）。
library;

import 'dart:async' show Timer;
import 'dart:io' show File;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/playback/playback_notifier.dart';
import '../services/scraper/scrape_controller.dart';
import '../stores/app_prefs.dart';
import '../stores/data_dir.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import '../app/theme_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/common/glass_surface.dart';
import '../widgets/player/s_controls.dart';
import '../widgets/common/toast.dart';
import '../widgets/common/anim.dart';
import 'streaming_server_list.dart';

void showSettingsDialog(BuildContext context, {SettingsCategory? category}) {
  showDialog<void>(
    context: context,
    // 全局变暗遮罩（统一所有弹窗样式）
    barrierColor: Colors.black.withValues(alpha: 0.5),
    builder: (_) => SettingsDialog(initialCategory: category),
  );
}

/// 设置分类（公开：流媒体页「前往设置」需指定媒体源分类）。
enum SettingsCategory {
  appearance(Icons.palette_outlined),
  playback(Icons.play_circle_outline),
  lyrics(Icons.lyrics_outlined),
  preset(Icons.healing_outlined),
  download(Icons.download_outlined),
  storage(Icons.storage_outlined),
  scrape(Icons.auto_fix_high),
  mediaSource(Icons.dns_outlined),
  about(Icons.info_outline),
  /// 开发者（隐藏分类：仅开启开发者模式后可见；开启方式为关于页
  /// 长按「版本」10 秒）。
  developer(Icons.engineering_outlined);

  const SettingsCategory(this.icon);
  final IconData icon;

  String label(AppLocalizations l10n) => switch (this) {
        appearance => l10n.settingsCatAppearance,
        playback => l10n.settingsCatPlayback,
        lyrics => l10n.settingsCatLyrics,
        preset => l10n.settingsCatPreset,
        download => l10n.settingsCatDownload,
        storage => l10n.settingsCatStorage,
        scrape => l10n.settingsCatScrape,
        mediaSource => l10n.settingsCatMediaSource,
        about => l10n.settingsCatAbout,
        developer => l10n.settingsCatDeveloper,
      };

  String subtitle(AppLocalizations l10n) => switch (this) {
        appearance => l10n.settingsAppearanceSubtitle,
        playback => l10n.settingsPlaybackSubtitle,
        lyrics => l10n.settingsLyricsSubtitle,
        preset => l10n.settingsPresetSubtitle,
        download => l10n.settingsDownloadSubtitle,
        storage => l10n.settingsStorageSubtitle,
        scrape => l10n.settingsScrapeSubtitle,
        mediaSource => l10n.settingsMediaSourceSubtitle,
        about => l10n.settingsAboutSubtitle,
        developer => l10n.settingsDeveloperSubtitle,
      };

  /// 该分类是否在设置导航中显示：开发者分类仅在开启开发者模式后出现；
  /// 下载分类（下载接口）在开发者模式下才可见。
  bool visible(bool developerMode) {
    if (this == SettingsCategory.developer) return developerMode;
    if (this == SettingsCategory.download) return developerMode;
    return true;
  }
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
  late SettingsCategory _category = widget.initialCategory ?? SettingsCategory.appearance;
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';
  String _version = '';
  late final TextEditingController _downloadRootCtrl;
  late final TextEditingController _downloadTemplateCtrl;
  late final TextEditingController _scrapeDirsCtrl;
  double? _downloadConcurrentDraft;
  double? _downloadSpeedDraft;
  double? _downloadHistoryLimitDraft;

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
    _downloadRootCtrl =
        TextEditingController(text: ref.read(appPrefsProvider).downloadRoot);
    _downloadTemplateCtrl = TextEditingController(
        text: ref.read(appPrefsProvider).downloadFilenameTemplate);
    _scrapeDirsCtrl = TextEditingController(
        text: ref.read(appPrefsProvider).scrapeDirs.join('\n'));
  }

  Future<void> _loadVersion() async {
    try {
      final data = await rootBundle.loadString('pubspec.yaml');
      final match =
          RegExp(r'^version:\s*([0-9][^\s#]*)(?:\s*#.*)?$', multiLine: true)
              .firstMatch(data);
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
    toast(l10n.settingsDeveloperEnabled,
        type: ToastType.success, duration: const Duration(milliseconds: 1600));
    if (mounted) setState(() => _category = SettingsCategory.developer);
  }

  @override
  void dispose() {
    _devHoldTimer?.cancel();
    _searchCtrl.dispose();
    _downloadRootCtrl.dispose();
    _downloadTemplateCtrl.dispose();
    _scrapeDirsCtrl.dispose();
    super.dispose();
  }

  List<_SearchEntry> _buildSearchIndex(AppLocalizations l10n) {
    return [
      _SearchEntry(SettingsCategory.appearance, l10n.settingsThemeMode, l10n.settingsThemeModeDesc, Icons.dark_mode_outlined),
      _SearchEntry(SettingsCategory.appearance, l10n.settingsThemeSource, l10n.settingsSearchThemeSourceSubtitle, Icons.color_lens_outlined),
      _SearchEntry(SettingsCategory.appearance, l10n.settingsGlobalTint, l10n.settingsSearchGlobalTintSubtitle, Icons.tonality_outlined),
      _SearchEntry(SettingsCategory.appearance, l10n.settingsAppearanceStyle, l10n.settingsSearchBackgroundSubtitle, Icons.image_outlined),
      _SearchEntry(SettingsCategory.appearance, l10n.settingsRouteTransition, l10n.settingsSearchRouteTransitionSubtitle, Icons.animation_outlined),
      _SearchEntry(SettingsCategory.appearance, l10n.settingsSidebarCollapsed, l10n.settingsSearchSidebarSubtitle, Icons.menu_open),
      _SearchEntry(SettingsCategory.appearance, l10n.settingsFloatingBar, l10n.settingsSearchFloatingBarSubtitle, Icons.rounded_corner),
      _SearchEntry(SettingsCategory.appearance, l10n.settingsSectionFont, l10n.settingsSearchFontSubtitle, Icons.font_download_outlined),
      _SearchEntry(SettingsCategory.appearance, l10n.settingsLanguageTitle, l10n.settingsSearchLanguageSubtitle, Icons.language_outlined),
      _SearchEntry(SettingsCategory.appearance, l10n.settingsCoverRadius, l10n.settingsSearchCoverRadiusSubtitle, Icons.crop_square),
      _SearchEntry(SettingsCategory.appearance, l10n.settingsPassthrough, l10n.settingsSearchPassthroughSubtitle, Icons.high_quality_outlined),
      _SearchEntry(SettingsCategory.playback, l10n.settingsSessionMemory, l10n.settingsSearchSessionMemorySubtitle, Icons.history),
      _SearchEntry(SettingsCategory.playback, l10n.settingsAutoPlay, l10n.settingsSearchAutoPlaySubtitle, Icons.play_circle_outline),
      _SearchEntry(SettingsCategory.playback, l10n.settingsSpectrum, l10n.settingsSearchSpectrumSubtitle, Icons.graphic_eq),
      _SearchEntry(SettingsCategory.playback, l10n.settingsSpectrumBarWidth, l10n.settingsSearchSpectrumWidthSubtitle, Icons.view_column_outlined),
      _SearchEntry(SettingsCategory.playback, l10n.settingsTransitionStyle, l10n.settingsTransitionStyleDesc, Icons.animation_outlined),
      _SearchEntry(SettingsCategory.lyrics, l10n.settingsPlayerLyrics, l10n.settingsSearchPlayerLyricsSubtitle, Icons.lyrics_outlined),
      _SearchEntry(SettingsCategory.lyrics, l10n.settingsBarLyrics, l10n.settingsBarLyricsOn, Icons.menu_book_outlined),
      _SearchEntry(SettingsCategory.lyrics, l10n.settingsBarEnhancedLyrics, l10n.settingsBarEnhancedLyricsOn, Icons.mic_external_on_outlined),
      _SearchEntry(SettingsCategory.lyrics, l10n.settingsLyricFontSize, l10n.settingsSearchLyricFontSizeSubtitle, Icons.format_size),
      _SearchEntry(SettingsCategory.lyrics, l10n.settingsLyricLineHeight, l10n.settingsSearchLyricLineHeightSubtitle, Icons.line_weight),
      _SearchEntry(SettingsCategory.lyrics, l10n.settingsSearchColorTitle, l10n.settingsSearchColorSubtitle, Icons.palette_outlined),
      _SearchEntry(SettingsCategory.lyrics, l10n.settingsSearchDesktopLyricsTitle, l10n.settingsSearchDesktopLyricsSubtitle, Icons.desktop_windows_outlined),
      _SearchEntry(SettingsCategory.preset, l10n.settingsPerformanceMode, l10n.settingsPerformanceModeOn, Icons.bolt_outlined),
      _SearchEntry(SettingsCategory.preset, l10n.settingsSearchDjModeTitle, l10n.settingsDjModeOn, Icons.auto_fix_high_outlined),
      _SearchEntry(SettingsCategory.preset, l10n.settingsUncensor, l10n.settingsSearchUncensorSubtitle, Icons.auto_fix_normal_outlined),
      _SearchEntry(SettingsCategory.preset, l10n.settingsHideVip, l10n.settingsSearchHideVipSubtitle, Icons.workspace_premium_outlined),
      _SearchEntry(SettingsCategory.preset, l10n.settingsHideQuality, l10n.settingsSearchHideQualitySubtitle, Icons.high_quality_outlined),
      _SearchEntry(SettingsCategory.preset, l10n.settingsShowSubtitle, l10n.settingsSearchSubtitleSubtitle, Icons.subtitles_outlined),
      _SearchEntry(SettingsCategory.download, l10n.settingsDataDir, l10n.settingsSearchDownloadDirSubtitle, Icons.folder_outlined),
      _SearchEntry(SettingsCategory.download, l10n.settingsSearchFilenameTitle, l10n.settingsSearchFilenameSubtitle, Icons.text_fields_outlined),
      _SearchEntry(SettingsCategory.download, l10n.settingsDownloadConcurrent, l10n.settingsSearchConcurrentSubtitle, Icons.speed_outlined),
      _SearchEntry(SettingsCategory.download, l10n.settingsDownloadSpeedLimit, l10n.settingsSearchSpeedLimitSubtitle, Icons.speed_outlined),
      _SearchEntry(SettingsCategory.download, l10n.settingsDownloadQuality, l10n.settingsSearchQualitySubtitle, Icons.high_quality_outlined),
      _SearchEntry(SettingsCategory.download, l10n.settingsDownloadGrouping, l10n.settingsSearchGroupingSubtitle, Icons.folder_copy_outlined),
      _SearchEntry(SettingsCategory.download, l10n.settingsDownloadHistoryLimit, l10n.settingsSearchHistoryLimitSubtitle, Icons.history_outlined),
      _SearchEntry(SettingsCategory.storage, l10n.settingsDataDir, l10n.settingsSearchStorageSubtitle, Icons.folder_outlined),
      _SearchEntry(SettingsCategory.scrape, l10n.settingsCatScrape, l10n.settingsScrapeSubtitle, Icons.auto_fix_high),
      _SearchEntry(SettingsCategory.mediaSource, l10n.settingsCatMediaSource, l10n.settingsMediaSourceSubtitle, Icons.dns_outlined),
      _SearchEntry(SettingsCategory.about, l10n.settingsVersion, l10n.settingsSearchAboutSubtitle, Icons.info_outline),
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
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateCategoryIndicator());
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
                          icon: Icon(Icons.close, color: scheme.onSurfaceVariant),
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
                                  _buildCategoryItem(scheme, cat, l10n, animated),
                            ],
                          ),
                          // 滑动高亮指示条（对齐侧边栏 animated 模式：
                          // left 跟随选中项左缘，top/height 上下各内缩 10px）
                          if (animated && _catIndicatorReady)
                            AnimatedPositioned(
                              duration: animDuration(
                                  context, const Duration(milliseconds: 250)),
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

  Widget _buildCategoryItem(ColorScheme scheme, SettingsCategory cat,
      AppLocalizations l10n, bool animated) {
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
                          context, const Duration(milliseconds: 150)),
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
                            fontWeight:
                                selected ? FontWeight.w600 : FontWeight.w400,
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
                SettingsCategory.appearance => _buildAppearance(scheme, l10n),
                SettingsCategory.playback => _buildPlayback(scheme, l10n),
                SettingsCategory.lyrics => _buildLyrics(scheme, l10n),
                SettingsCategory.preset => _buildPreset(scheme, l10n),
                SettingsCategory.download => _buildDownload(scheme, l10n),
                SettingsCategory.storage => _buildStorage(scheme, l10n),
                SettingsCategory.scrape => _buildScrape(scheme, l10n),
                SettingsCategory.mediaSource =>
                  StreamingServerList(),
                SettingsCategory.about => _buildAbout(scheme, l10n),
                SettingsCategory.developer => _buildDeveloper(scheme, l10n),
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
    final index = _buildSearchIndex(l10n)
        .where((e) => e.category.visible(devMode))
        .toList();
    final matches = index.where((e) => _searchMatch(e, q, l10n)).toList();
    if (matches.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search_off,
                size: 36, color: scheme.onSurfaceVariant.withValues(alpha: 0.5)),
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
            if (cat.visible(devMode) && matches.any((e) => e.category == cat)) ...[
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
                Icon(Icons.chevron_right,
                    size: 16, color: scheme.onSurfaceVariant),
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
      spans.add(TextSpan(
        text: text.substring(idx, idx + q.length),
        style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w700),
      ));
      start = idx + q.length;
    }
    return spans;
  }

  static const _accentPresets = <int?>[
    null,
    0xFF5B8CFF,
    0xFF9B8CFF,
    0xFFFF6B9D,
    0xFFFF6B61,
    0xFFFFA24D,
    0xFF4DDB9B,
    0xFF4DD8E0,
  ];

  Widget _buildAppearance(ColorScheme scheme, AppLocalizations l10n) {
    final themeMode = ref.watch(themeModeProvider);
    final prefs = ref.watch(appPrefsProvider);
    final accent = prefs.accent;
    final notifier = ref.read(appPrefsProvider.notifier);
    // 图片风格「有效」才有背景子项可调（无图时回退 solid，对齐原版 effectiveStyle）
    final imageStyle =
        prefs.appearanceStyle == 'image' && prefs.backgroundImage != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── 主题 ──
        _section(scheme, l10n.settingsSectionTheme, [
          _SettingTile(
            icon: Icons.dark_mode_outlined,
            title: l10n.settingsThemeMode,
            subtitle: l10n.settingsThemeModeDesc,
            trailing: SSegmented<ThemeMode>(
              options: [
                SSegmentedOption(ThemeMode.light, l10n.settingsThemeLight),
                SSegmentedOption(ThemeMode.dark, l10n.settingsThemeDark),
                SSegmentedOption(ThemeMode.system, l10n.settingsThemeSystem),
              ],
              selected: themeMode,
              onChanged: (mode) =>
                  ref.read(themeModeProvider.notifier).setMode(mode),
            ),
          ),
        ], note: l10n.settingsThemeNote),
        const SizedBox(height: 20),

        // 主题色来源（default / custom / cover / solid）
        _section(scheme, l10n.settingsSectionAccent, [
          _SettingTile(
            icon: Icons.color_lens_outlined,
            title: l10n.settingsThemeSource,
            subtitle: l10n.settingsThemeSourceDesc,
            trailing: SSegmented<String>(
              options: [
                SSegmentedOption(
                    'default', l10n.settingsThemeSourceDefault),
                SSegmentedOption(
                    'custom', l10n.settingsThemeSourceCustom),
                SSegmentedOption('cover', l10n.settingsThemeSourceCover),
                SSegmentedOption('solid', l10n.settingsThemeSourceSolid),
              ],
              selected: prefs.themeSource,
              onChanged: (v) => notifier.setThemeSource(v),
            ),
          ),
        ]),
        if (prefs.themeSource == 'custom') ...[
          const SizedBox(height: 8),
          _card(
            scheme,
            children: [
              _SettingTile(
                icon: Icons.palette_outlined,
                title: l10n.settingsAccentTitle,
                subtitle: l10n.settingsThemeSourceCustomHint,
                trailing: _accentSwatches(scheme, accent, l10n),
              ),
            ],
          ),
        ] else if (prefs.themeSource == 'cover') ...[
          const SizedBox(height: 8),
          _noteText(scheme, l10n.settingsThemeSourceCoverHint),
        ],
        const SizedBox(height: 12),

        // 全局着色
        _card(
          scheme,
          children: [
            _switchTile(
              Icons.tonality_outlined,
              l10n.settingsGlobalTint,
              l10n.settingsGlobalTintDesc,
              prefs.globalTint,
              notifier.setGlobalTint,
            ),
          ],
        ),
        const SizedBox(height: 8),
        _noteText(scheme, l10n.settingsGlobalTintNote),
        const SizedBox(height: 20),

        // ── 外观风格（纯色 / 图片背景）──
        _section(scheme, l10n.settingsSectionStyle, [
          _SettingTile(
            icon: Icons.image_outlined,
            title: l10n.settingsAppearanceStyle,
            subtitle: l10n.settingsAppearanceStyleDesc,
            trailing: SSegmented<String>(
              options: [
                SSegmentedOption(
                    'solid', l10n.settingsAppearanceStyleSolid),
                SSegmentedOption(
                    'image', l10n.settingsAppearanceStyleImage),
              ],
              selected: prefs.appearanceStyle,
              onChanged: (v) => notifier.setAppearanceStyle(v),
            ),
          ),
        ]),
        if (prefs.appearanceStyle == 'image') ...[
          const SizedBox(height: 8),
          _backgroundCard(scheme, prefs, l10n, notifier),
          if (imageStyle) ...[
            const SizedBox(height: 12),
            _card(
              scheme,
              children: [
                _sliderTile(
                  Icons.blur_on_outlined,
                  l10n.settingsBackgroundBlur,
                  l10n.settingsBackgroundBlurDesc(prefs.backgroundBlur),
                  value: prefs.backgroundBlur.toDouble(),
                  min: 0,
                  max: 80,
                  divisions: 16,
                  label: '${prefs.backgroundBlur}px',
                  onChanged: (v) => notifier.setBackground(blur: v.round()),
                ),
                _sliderTile(
                  Icons.dark_mode_outlined,
                  l10n.settingsBackgroundDim,
                  l10n.settingsBackgroundDimDesc(prefs.backgroundDim),
                  value: prefs.backgroundDim,
                  min: 0.3,
                  max: 0.9,
                  divisions: 12,
                  label: '${(prefs.backgroundDim * 100).round()}%',
                  onChanged: (v) => notifier.setBackground(dim: v),
                ),
                _sliderTile(
                  Icons.zoom_out_map_outlined,
                  l10n.settingsBackgroundScale,
                  l10n.settingsBackgroundScaleDesc(prefs.backgroundScale),
                  value: prefs.backgroundScale,
                  min: 1,
                  max: 2,
                  divisions: 20,
                  label: '${prefs.backgroundScale.toStringAsFixed(1)}x',
                  onChanged: (v) => notifier.setBackground(scale: v),
                ),
              ],
            ),
          ],
        ],
        const SizedBox(height: 20),

        // ── 布局 ──
        _section(scheme, l10n.settingsSectionLayout, [
          _switchTile(
            Icons.rounded_corner,
            l10n.settingsFloatingBar,
            prefs.floatingPlayerBar
                ? l10n.settingsFloatingBarOn
                : l10n.settingsFloatingBarOff,
            prefs.floatingPlayerBar,
            notifier.setFloatingPlayerBar,
          ),
          _switchTile(
            prefs.sidebarCollapsed
                ? Icons.menu_open
                : Icons.menu_rounded,
            l10n.settingsSidebarCollapsed,
            l10n.settingsSidebarCollapsedDesc,
            prefs.sidebarCollapsed,
            (value) => notifier.setSidebar(collapsed: value),
          ),
          _SettingTile(
            icon: Icons.arrow_right_alt,
            title: l10n.settingsSidebarNavStyle,
            subtitle: l10n.settingsSidebarNavStyleDesc,
            trailing: SSegmented<String>(
              options: [
                SSegmentedOption(
                    'default', l10n.settingsSidebarNavStyleDefault),
                SSegmentedOption(
                    'animated', l10n.settingsSidebarNavStyleAnimated),
              ],
              selected: prefs.sidebarNavStyle,
              onChanged: (v) => notifier.setSidebar(navStyle: v),
            ),
          ),
          _SettingTile(
            icon: Icons.animation_outlined,
            title: l10n.settingsRouteTransition,
            subtitle: l10n.settingsRouteTransitionDesc,
            trailing: SSegmented<String>(
              options: [
                SSegmentedOption('none', l10n.settingsRouteTransitionNone),
                SSegmentedOption('fade', l10n.settingsRouteTransitionFade),
                SSegmentedOption('slide', l10n.settingsRouteTransitionSlide),
                SSegmentedOption('zoom', l10n.settingsRouteTransitionZoom),
              ],
              selected: prefs.routeTransition,
              onChanged: (v) => notifier.setRouteTransition(v),
            ),
          ),
        ]),
        const SizedBox(height: 20),

        // ── 字体 ──
        _section(scheme, l10n.settingsSectionFont, [
          _SettingTile(
            icon: Icons.font_download_outlined,
            title: l10n.settingsFontTitle,
            subtitle: switch (prefs.fontFamily) {
              'MiSans' => l10n.settingsFontMiSans,
              'Noto Sans SC' => l10n.settingsFontNoto,
              _ => l10n.settingsFontHarmony,
            },
            trailing: SSegmented<String>(
              options: [
                SSegmentedOption('MiSans', l10n.settingsFontMiSansLabel),
                SSegmentedOption('Noto Sans SC', l10n.settingsFontNotoLabel),
                SSegmentedOption('HarmonyOS Sans SC', l10n.settingsFontHarmonyLabel),
              ],
              selected: prefs.fontFamily,
              onChanged: (family) => notifier.setFontFamily(family),
            ),
          ),
        ]),
        const SizedBox(height: 20),

        // ── 语言 ──
        _section(scheme, l10n.settingsSectionLanguage, [
          _SettingTile(
            icon: Icons.language_outlined,
            title: l10n.settingsLanguageTitle,
            subtitle: l10n.settingsLanguageDesc,
            trailing: _languageDropdown(scheme, prefs.locale, l10n),
          ),
        ]),
        const SizedBox(height: 20),

        // ── 封面圆角 ──
        _section(scheme, l10n.settingsSectionCover, [
          _SettingTile(
            icon: Icons.crop_square,
            title: l10n.settingsCoverRadius,
            subtitle: prefs.coverRadius == 0
                ? l10n.settingsCoverRadiusSharp
                : l10n.settingsCoverRadiusPx(prefs.coverRadius.round()),
            trailing: SSegmented<double>(
              options: [
                SSegmentedOption(0, l10n.settingsCoverRadiusSharpLabel),
                SSegmentedOption(8, l10n.settingsCoverRadiusRoundedLabel),
                SSegmentedOption(12, l10n.settingsCoverRadiusLargeLabel),
              ],
              selected: prefs.coverRadius,
              onChanged: (v) => notifier.setCoverRadius(v),
            ),
          ),
        ]),
      ],
    );
  }

  /// 背景图选择卡（对齐原版 BackgroundImagePicker：横向预览 + 替换/清除）。
  Widget _backgroundCard(ColorScheme scheme, AppPrefs prefs,
      AppLocalizations l10n, AppPrefsNotifier notifier) {
    final path = prefs.backgroundImage;
    return _card(
      scheme,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(Icons.wallpaper_outlined,
                    size: 18, color: scheme.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.settingsBackgroundImage,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      path ?? l10n.settingsBackgroundImageDesc,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: scheme.onSurfaceVariant.withValues(alpha: 0.75),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              // 横向预览（对齐原版 96×56）
              if (path != null) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image.file(
                    File(path),
                    width: 96,
                    height: 56,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Container(
                      width: 96,
                      height: 56,
                      color: scheme.onSurface.withValues(alpha: 0.06),
                      child: Icon(Icons.broken_image_outlined,
                          size: 20,
                          color: scheme.onSurfaceVariant.withValues(alpha: 0.6)),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              SizedBox(
                height: 28,
                child: SButton(
                  label: path == null
                      ? l10n.settingsBackgroundPick
                      : l10n.settingsBackgroundReplace,
                  variant: SButtonVariant.secondary,
                  size: SButtonSize.small,
                  onPressed: _pickBackgroundImage,
                ),
              ),
              if (path != null) ...[
                const SizedBox(width: 6),
                SizedBox(
                  height: 28,
                  child: SButton(
                    label: l10n.settingsBackgroundClear,
                    variant: SButtonVariant.ghost,
                    size: SButtonSize.small,
                    onPressed: () => notifier.setBackground(image: null),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _pickBackgroundImage() async {
    const typeGroup = XTypeGroup(
      label: 'images',
      extensions: ['png', 'jpg', 'jpeg', 'webp', 'bmp', 'gif'],
    );
    String? path;
    try {
      final file = await openFile(acceptedTypeGroups: const [typeGroup]);
      path = file?.path;
    } catch (_) {
      // 文件选择器不可用时静默忽略（自用项目，无返回值不阻塞）
    }
    if (path == null || !mounted) return;
    ref.read(appPrefsProvider.notifier).setBackground(image: path);
  }

  static const _localeSystem = '__system__';

  List<(String, String)> _localeOptions(AppLocalizations l10n) => [
        (_localeSystem, l10n.settingsLangSystem),
        ('zh-CN', '简体中文'),
        ('zh-TW', '繁體中文'),
        ('en', 'English'),
        ('ja', '日本語'),
        ('ko', '한국어'),
        ('es', 'Español'),
        ('fr', 'Français'),
        ('de', 'Deutsch'),
      ];

  /// 语言下拉（紧凑 DropdownButton：展开/收起自带高度过渡 + 箭头旋转动效；
  /// 受控 value 语言切换后自动更新，无需额外包裹层）。
  Widget _languageDropdown(
      ColorScheme scheme, String? current, AppLocalizations l10n) {
    final selected = current ?? _localeSystem;
    return Theme(
      // 隐藏 DropdownButton 的悬停高亮 / 点击涟漪效果（纯文本按钮样式）
      data: Theme.of(context).copyWith(
        hoverColor: Colors.transparent,
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: scheme.onSurface.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(AppRadius.control),
        ),
        child: DropdownButton<String>(
          value: selected,
          isDense: true,
          underline: const SizedBox.shrink(),
          borderRadius: BorderRadius.circular(10),
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: scheme.onSurface,
          ),
          icon: Icon(
            Icons.arrow_drop_down,
            size: 20,
            color: scheme.onSurfaceVariant,
          ),
          // 选中项固定最大宽度防截断溢出（弹出菜单仍按 items 全宽显示）
          selectedItemBuilder: (context) => [
            for (final (_, label) in _localeOptions(l10n))
              Align(
                alignment: Alignment.centerLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 110),
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
          ],
          onChanged: (code) {
            if (code == null) return;
            ref.read(appPrefsProvider.notifier).setLocale(
                code == _localeSystem ? null : code);
          },
          items: [
            for (final (code, label) in _localeOptions(l10n))
              DropdownMenuItem(value: code, child: Text(label)),
          ],
        ),
      ),
    );
  }

  Widget _accentSwatches(ColorScheme scheme, int? accent, AppLocalizations l10n) {
    final currentColor = accent == null ? scheme.primary : Color(accent);
    final customSelected =
        accent != null && !_accentPresets.contains(accent);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final v in _accentPresets)
          Tooltip(
            message: v == null ? l10n.settingsAccentDefaultTooltip : '#${(v & 0xFFFFFF).toRadixString(16).toUpperCase()}',
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () {
                ref.read(appPrefsProvider.notifier).setAccent(v);
              },
              child: _swatchCircle(
                scheme,
                color: v == null ? scheme.primary : Color(v),
                selected: accent == v,
                checkColor: v == null
                    ? scheme.onPrimary
                    : Color(v).computeLuminance() > 0.5
                        ? Colors.black
                        : Colors.white,
              ),
            ),
          ),
        const SizedBox(width: 4),
        Tooltip(
          message: l10n.settingsAccentCustomTooltip,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () => _pickAccent(scheme, accent, l10n),
            child: _swatchCircle(
              scheme,
              color: currentColor,
              selected: customSelected,
              icon: Icons.colorize,
              iconColor: customSelected
                  ? scheme.primary
                  : currentColor.computeLuminance() > 0.5
                      ? Colors.black
                      : Colors.white,
            ),
          ),
        ),
      ],
    );
  }

  Widget _swatchCircle(
    ColorScheme scheme, {
    required Color color,
    required bool selected,
    Color? checkColor,
    IconData? icon,
    Color? iconColor,
  }) {
    return Container(
      width: 26,
      height: 26,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        border: Border.all(
          color: selected ? scheme.onSurface : Colors.transparent,
          width: 2,
        ),
      ),
      child: icon != null
          ? Icon(icon, size: 14, color: iconColor)
          : (selected
              ? Icon(Icons.check, size: 14, color: checkColor)
              : null),
    );
  }

  Future<void> _pickAccent(ColorScheme scheme, int? accent, AppLocalizations l10n) async {
    final color = await showDialog<Color>(
      context: context,
      // 与其他弹窗一致的全局变暗遮罩（而非 Flutter 默认 black54 遮罩）
      barrierColor: Colors.black.withValues(alpha: 0.5),
      builder: (_) => _AccentPickerDialog(
        initial: accent == null ? scheme.primary : Color(accent),
        l10n: l10n,
      ),
    );
    if (color == null || !mounted) return;
    ref.read(appPrefsProvider.notifier).setAccent(color.toARGB32());
  }

  Widget _buildPlayback(ColorScheme scheme, AppLocalizations l10n) {
    final prefs = ref.watch(appPrefsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _section(scheme, l10n.settingsSectionAudio, [
          _switchTile(
            prefs.passthrough
                ? Icons.high_quality_outlined
                : Icons.transform_rounded,
            l10n.settingsPassthrough,
            prefs.passthrough
                ? l10n.settingsPassthroughOn
                : l10n.settingsPassthroughOff,
            prefs.passthrough,
            (value) {
              ref.read(appPrefsProvider.notifier).setPassthrough(value);
              ref.read(playbackProvider.notifier).reload();
            },
          ),
        ], note: l10n.settingsPassthroughNote),
        const SizedBox(height: 20),
        _section(scheme, l10n.settingsSectionMemory, [
          _switchTile(
            prefs.sessionMemory ? Icons.history : Icons.history_toggle_off,
            l10n.settingsSessionMemory,
            prefs.sessionMemory
                ? l10n.settingsSessionMemoryOn
                : l10n.settingsSessionMemoryOff,
            prefs.sessionMemory,
            (value) =>
                ref.read(appPrefsProvider.notifier).setMemoryEnabled(value),
          ),
          _switchTile(
            prefs.autoPlayOnLaunch
                ? Icons.play_circle_outline
                : Icons.pause_circle_outline,
            l10n.settingsAutoPlay,
            !prefs.sessionMemory
                ? l10n.settingsAutoPlayNeedMemory
                : prefs.autoPlayOnLaunch
                    ? l10n.settingsAutoPlayOn
                    : l10n.settingsAutoPlayOff,
            prefs.sessionMemory && prefs.autoPlayOnLaunch,
            prefs.sessionMemory
                ? (value) => ref
                    .read(appPrefsProvider.notifier)
                    .setAutoPlayOnLaunch(value)
                : null,
          ),
        ]),
        const SizedBox(height: 20),
        _section(scheme, l10n.settingsSectionClose, [
          _SettingTile(
            icon: Icons.power_settings_new_outlined,
            title: l10n.settingsCloseBehavior,
            subtitle: switch (prefs.closeBehavior) {
              'background' => l10n.settingsCloseBehaviorBackground,
              'quit' => l10n.settingsCloseBehaviorQuit,
              _ => l10n.settingsCloseBehaviorAsk,
            },
            trailing: DropdownButton<String>(
              value: prefs.closeBehavior,
              isDense: true,
              underline: const SizedBox.shrink(),
              borderRadius: BorderRadius.circular(10),
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
              icon: Icon(
                Icons.arrow_drop_down,
                color: scheme.onSurfaceVariant,
              ),
              onChanged: (v) {
                if (v == null) return;
                ref.read(appPrefsProvider.notifier).setCloseBehavior(v);
              },
              items: [
                DropdownMenuItem(
                  value: 'ask',
                  child: Text(l10n.settingsCloseBehaviorAsk),
                ),
                DropdownMenuItem(
                  value: 'background',
                  child: Text(l10n.settingsCloseBehaviorBackground),
                ),
                DropdownMenuItem(
                  value: 'quit',
                  child: Text(l10n.settingsCloseBehaviorQuit),
                ),
              ],
            ),
          ),
        ]),
        const SizedBox(height: 20),
        _section(scheme, l10n.settingsSectionSpectrum, [
          _switchTile(
            prefs.enableSpectrum
                ? Icons.graphic_eq
                : Icons.graphic_eq_outlined,
            l10n.settingsSpectrum,
            prefs.enableSpectrum
                ? l10n.settingsSpectrumOn
                : l10n.settingsSpectrumOff,
            prefs.enableSpectrum,
            (value) => ref
                .read(appPrefsProvider.notifier)
                .setSpectrumEnabled(value),
          ),
          // 封面跟随节拍缩放（播放界面封面随鼓点脉冲缩放；依赖频谱数据，
          // 性能模式自动停用）
          _switchTile(
            prefs.coverBeatScale
                ? Icons.music_note
                : Icons.music_note_outlined,
            l10n.settingsCoverBeatScale,
            prefs.coverBeatScale
                ? l10n.settingsCoverBeatScaleOn
                : l10n.settingsCoverBeatScaleOff,
            prefs.coverBeatScale,
            (value) => ref
                .read(appPrefsProvider.notifier)
                .setCoverBeatScale(value),
          ),
          _sliderTile(
            Icons.view_column_outlined,
            l10n.settingsSpectrumBarWidth,
            l10n.settingsSpectrumBarWidthDesc(prefs.spectrumBarWidth),
            value: prefs.spectrumBarWidth.toDouble(),
            min: 1,
            max: 12,
            divisions: 11,
            label: '${prefs.spectrumBarWidth}px',
            onChanged: (v) => ref
                .read(appPrefsProvider.notifier)
                .setSpectrumBarWidth(v.round()),
          ),
          // 播放条迷你频谱：与全局「频谱」开关解耦（SpectrumView.enabled
          // 优先）；有歌词且开启「播放条歌词」时迷你频谱不显示
          _switchTile(
            prefs.barSpectrum
                ? Icons.bar_chart
                : Icons.bar_chart_outlined,
            l10n.settingsBarSpectrum,
            prefs.barSpectrum
                ? l10n.settingsBarSpectrumOn
                : l10n.settingsBarSpectrumOff,
            prefs.barSpectrum,
            (value) => ref
                .read(appPrefsProvider.notifier)
                .setBarDisplay(barSpectrum: value),
          ),
        ]),
        const SizedBox(height: 20),
        _section(scheme, l10n.settingsTransitionStyle, [
          _SettingTile(
            icon: Icons.animation_outlined,
            title: l10n.settingsTransitionStyle,
            subtitle: l10n.settingsTransitionStyleDesc,
            trailing: SSegmented<String>(
              options: [
                SSegmentedOption('scale', l10n.settingsTransitionStyleScale),
                SSegmentedOption('slide', l10n.settingsTransitionStyleSlide),
              ],
              selected: prefs.transitionStyle,
              onChanged: (v) => ref
                  .read(appPrefsProvider.notifier)
                  .setTransitionStyle(v),
            ),
          ),
        ]),
        const SizedBox(height: 20),
        _section(scheme, l10n.settingsSectionShortcuts, [
          _SettingTile(
            icon: Icons.space_bar,
            title: l10n.settingsShortcutSpace,
            subtitle: l10n.settingsShortcutSpaceDesc,
            trailing: const SizedBox.shrink(),
          ),
          _SettingTile(
            icon: Icons.swap_horiz,
            title: l10n.settingsShortcutArrows,
            subtitle: l10n.settingsShortcutArrowsDesc,
            trailing: const SizedBox.shrink(),
          ),
          _SettingTile(
            icon: Icons.search,
            title: l10n.settingsShortcutSearch,
            subtitle: l10n.commonSearch,
            trailing: const SizedBox.shrink(),
          ),
          _SettingTile(
            icon: Icons.library_music_outlined,
            title: l10n.settingsShortcutLibrary,
            subtitle: l10n.settingsShortcutLibraryDesc,
            trailing: const SizedBox.shrink(),
          ),
          _SettingTile(
            icon: Icons.keyboard_return,
            title: l10n.settingsShortcutEsc,
            subtitle: l10n.settingsShortcutEscDesc,
            trailing: const SizedBox.shrink(),
          ),
        ]),
      ],
    );
  }

  static const _lyricColorPresets = <int>[
    0xFF4DA3FF,
    0xFFE8EAF2,
    0xFFFF6B9D,
    0xFFFFB84D,
    0xFF4DDB9B,
    0xFF9AA1B5,
    0xFF5B8CFF,
  ];

  Widget _buildLyrics(ColorScheme scheme, AppLocalizations l10n) {
    final prefs = ref.watch(appPrefsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _section(scheme, l10n.settingsSectionPlayerLyrics, [
          _switchTile(
            prefs.showLyricsInPlayer
                ? Icons.lyrics_outlined
                : Icons.lyrics,
            l10n.settingsPlayerLyrics,
            prefs.showLyricsInPlayer
                ? l10n.settingsPlayerLyricsOn
                : l10n.settingsPlayerLyricsOff,
            prefs.showLyricsInPlayer,
            (value) => ref
                .read(appPrefsProvider.notifier)
                .setShowLyricsInPlayer(value),
          ),
          // 播放条迷你歌词：有歌词时在播放条时间下方替代迷你频谱显示
          _switchTile(
            prefs.barLyrics
                ? Icons.menu_book_outlined
                : Icons.menu_book,
            l10n.settingsBarLyrics,
            prefs.barLyrics
                ? l10n.settingsBarLyricsOn
                : l10n.settingsBarLyricsOff,
            prefs.barLyrics,
            (value) => ref
                .read(appPrefsProvider.notifier)
                .setBarDisplay(barLyrics: value),
          ),
          // 播放条高级歌词：歌词含逐字时间轴（YRC/KRC）时卡拉OK 逐字高亮；
          // 开启时自动关闭翻译并禁用翻译开关（逐字高亮与翻译互斥）
          _switchTile(
            prefs.barEnhancedLyrics
                ? Icons.mic_external_on_outlined
                : Icons.mic_external_on,
            l10n.settingsBarEnhancedLyrics,
            prefs.barEnhancedLyrics
                ? l10n.settingsBarEnhancedLyricsOn
                : l10n.settingsBarEnhancedLyricsOff,
            prefs.barEnhancedLyrics,
            (value) {
              ref
                  .read(appPrefsProvider.notifier)
                  .setBarDisplay(barEnhancedLyrics: value);
              if (value) {
                ref.read(appPrefsProvider.notifier).setShowTranslation(false);
              }
            },
          ),
          // 显示翻译：全屏播放器歌词 + 播放条迷你歌词共用；卡拉OK 开启时禁用
          _switchTile(
            prefs.showTranslation
                ? Icons.translate
                : Icons.translate_outlined,
            l10n.settingsShowTranslation,
            prefs.showTranslation
                ? l10n.settingsShowTranslationOn
                : l10n.settingsShowTranslationOff,
            prefs.showTranslation,
            (value) => ref
                .read(appPrefsProvider.notifier)
                .setShowTranslation(value),
            enabled: !prefs.barEnhancedLyrics,
          ),
        ]),
        const SizedBox(height: 20),
        _section(scheme, l10n.settingsSectionLyricStyle, [
          _sliderTile(
            Icons.format_size,
            l10n.settingsLyricFontSize,
            l10n.settingsLyricFontSizeDesc(prefs.lyricFontSize.round()),
            value: prefs.lyricFontSize,
            min: 14,
            max: 28,
            divisions: 14,
            label: '${prefs.lyricFontSize.round()}px',
            onChanged: (v) => ref
                .read(appPrefsProvider.notifier)
                .setLyricStyle(fontSize: v),
          ),
          _sliderTile(
            Icons.line_weight,
            l10n.settingsLyricLineHeight,
            l10n.settingsLyricLineHeightDesc(prefs.lyricLineHeight.round()),
            value: prefs.lyricLineHeight,
            min: 42,
            max: 64,
            divisions: 11,
            label: '${prefs.lyricLineHeight.round()}px',
            onChanged: (v) => ref
                .read(appPrefsProvider.notifier)
                .setLyricStyle(lineHeight: v),
          ),
          _SettingTile(
            icon: Icons.palette_outlined,
            title: l10n.settingsLyricPlayedColor,
            subtitle: l10n.settingsLyricPlayedColorDesc,
            trailing: _colorSwatches(
              scheme,
              current: prefs.lyricPlayedColor,
              onChanged: (v) => ref
                  .read(appPrefsProvider.notifier)
                  .setLyricStyle(playedColor: v),
            ),
          ),
          _SettingTile(
            icon: Icons.palette_outlined,
            title: l10n.settingsLyricUnplayedColor,
            subtitle: l10n.settingsLyricUnplayedColorDesc,
            trailing: _colorSwatches(
              scheme,
              current: prefs.lyricUnplayedColor,
              onChanged: (v) => ref
                  .read(appPrefsProvider.notifier)
                  .setLyricStyle(unplayedColor: v),
            ),
          ),
        ], note: l10n.settingsLyricsNote),
      ],
    );
  }

  Widget _colorSwatches(
    ColorScheme scheme, {
    required int current,
    required ValueChanged<int> onChanged,
  }) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: WrapAlignment.end,
      children: [
        for (final v in _lyricColorPresets)
          Tooltip(
            message: '#${(v & 0xFFFFFF).toRadixString(16).toUpperCase()}',
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => onChanged(v),
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(v),
                  border: Border.all(
                    color: current == v
                        ? scheme.onSurface
                        : scheme.outline.withValues(alpha: 0.4),
                    width: 2,
                  ),
                ),
                child: current == v
                    ? Icon(
                        Icons.check,
                        size: 12,
                        color: Color(v).computeLuminance() > 0.5
                            ? Colors.black
                            : Colors.white,
                      )
                    : null,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildPreset(ColorScheme scheme, AppLocalizations l10n) {
    final prefs = ref.watch(appPrefsProvider);
    final notifier = ref.read(appPrefsProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 性能模式：关闭所有动效 + 自动关闭音频频谱（全局开关）
        _section(scheme, l10n.settingsPerformanceMode, [
          _switchTile(
            prefs.performanceMode ? Icons.bolt : Icons.bolt_outlined,
            l10n.settingsPerformanceMode,
            prefs.performanceMode
                ? l10n.settingsPerformanceModeOn
                : l10n.settingsPerformanceModeOff,
            prefs.performanceMode,
            notifier.setPerformanceMode,
          ),
        ]),
        const SizedBox(height: 20),
        _section(scheme, l10n.settingsSectionFilter, [
          _switchTile(
            prefs.fuckDjMode
                ? Icons.auto_fix_high
                : Icons.auto_fix_high_outlined,
            l10n.settingsDjMode,
            prefs.fuckDjMode
                ? l10n.settingsDjModeOn
                : l10n.settingsDjModeOff,
            prefs.fuckDjMode,
            (v) => notifier.setPreset(fuckDjMode: v),
          ),
        ]),
        const SizedBox(height: 20),
        _section(scheme, l10n.settingsSectionLyricsFilter, [
          _switchTile(
            prefs.uncensorProfanity
                ? Icons.auto_fix_normal
                : Icons.auto_fix_normal_outlined,
            l10n.settingsUncensor,
            prefs.uncensorProfanity
                ? l10n.settingsUncensorOn
                : l10n.settingsUncensorOff,
            prefs.uncensorProfanity,
            (v) => notifier.setPreset(uncensorProfanity: v),
          ),
        ]),
        const SizedBox(height: 20),
        _section(scheme, l10n.settingsSectionListDisplay, [
          _switchTile(
            Icons.workspace_premium_outlined,
            l10n.settingsHideVip,
            prefs.hideVipTag
                ? l10n.settingsHideVipOn
                : l10n.settingsHideVipOff,
            prefs.hideVipTag,
            (v) => notifier.setPreset(hideVipTag: v),
          ),
          _switchTile(
            Icons.high_quality_outlined,
            l10n.settingsHideQuality,
            prefs.hideQualityTag
                ? l10n.settingsHideQualityOn
                : l10n.settingsHideQualityOff,
            prefs.hideQualityTag,
            (v) => notifier.setPreset(hideQualityTag: v),
          ),
          _switchTile(
            prefs.showSubtitle
                ? Icons.subtitles
                : Icons.subtitles_off_outlined,
            l10n.settingsShowSubtitle,
            prefs.showSubtitle
                ? l10n.settingsShowSubtitleOn
                : l10n.settingsShowSubtitleOff,
            prefs.showSubtitle,
            (v) => notifier.setPreset(showSubtitle: v),
          ),
        ]),
      ],
    );
  }

  Widget _buildDownload(ColorScheme scheme, AppLocalizations l10n) {
    final prefs = ref.watch(appPrefsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _section(scheme, l10n.settingsSectionDir, [
          _pathFieldCard(
            scheme,
            l10n,
            icon: Icons.folder_outlined,
            ctrl: _downloadRootCtrl,
            hint: l10n.settingsDownloadRootHint,
            save: (v) => _saveDownloadRoot(v, l10n),
            restoreDefault: defaultDownloadRoot,
          ),
        ], note: l10n.settingsDownloadRootNote),
        const SizedBox(height: 20),
        _section(scheme, l10n.settingsSectionFilename, [
          _pathFieldCard(
            scheme,
            l10n,
            icon: Icons.text_fields_outlined,
            ctrl: _downloadTemplateCtrl,
            hint: l10n.settingsDownloadTemplateHint,
            save: (v) => _saveDownloadTemplate(v, l10n),
            restoreDefault: () => '{artist} - {title}',
          ),
        ], note: l10n.settingsDownloadTemplateNote),
        const SizedBox(height: 20),
        _section(scheme, l10n.settingsSectionQuality, [
          _SettingTile(
            icon: Icons.high_quality_outlined,
            title: l10n.settingsDownloadQuality,
            subtitle: l10n.settingsDownloadQualityDesc(l10nQualityLabel(l10n, prefs.downloadQuality)),
            trailing: SSegmented<String>(
              options: [
                for (final q in downloadQualityLevels)
                  SSegmentedOption(q, l10nQualityLabel(l10n, q)),
              ],
              selected: prefs.downloadQuality,
              onChanged: (q) => ref
                  .read(appPrefsProvider.notifier)
                  .setDownload(quality: q),
            ),
          ),
        ], note: l10n.settingsDownloadQualityNote),
        const SizedBox(height: 20),
        _section(scheme, l10n.settingsSectionConcurrent, [
          _sliderTile(
            Icons.speed_outlined,
            l10n.settingsDownloadConcurrent,
            l10n.settingsDownloadConcurrentDesc(prefs.downloadMaxConcurrent),
            value: _downloadConcurrentDraft ??
                prefs.downloadMaxConcurrent.toDouble(),
            min: 1,
            max: 5,
            divisions: 4,
            label: '${(_downloadConcurrentDraft ??
                prefs.downloadMaxConcurrent.toDouble()).round()}',
            width: 160,
            onChanged: (v) =>
                setState(() => _downloadConcurrentDraft = v),
            onChangeEnd: (v) {
              setState(() => _downloadConcurrentDraft = null);
              ref
                  .read(appPrefsProvider.notifier)
                  .setDownload(maxConcurrent: v.round());
            },
          ),
          _SettingTile(
            icon: Icons.folder_copy_outlined,
            title: l10n.settingsDownloadGrouping,
            subtitle: switch (prefs.downloadSubdirStrategy) {
              0 => l10n.settingsGroupingFlat,
              1 => l10n.settingsGroupingPlatform,
              _ => l10n.settingsGroupingArtist,
            },
            trailing: SSegmented<int>(
              options: [
                SSegmentedOption(0, l10n.settingsGroupingFlatLabel),
                SSegmentedOption(1, l10n.settingsGroupingPlatformLabel),
                SSegmentedOption(2, l10n.settingsGroupingArtistLabel),
              ],
              selected: prefs.downloadSubdirStrategy,
              onChanged: (v) => ref
                  .read(appPrefsProvider.notifier)
                  .setDownload(subdirStrategy: v),
            ),
          ),
        ]),
        const SizedBox(height: 20),
        _section(scheme, l10n.settingsSectionSpeedLimit, [
          _sliderTile(
            Icons.speed_outlined,
            l10n.settingsDownloadSpeedLimit,
            prefs.downloadSpeedLimit <= 0
                ? l10n.settingsSpeedUnlimited
                : l10n.settingsSpeedLimited(_fmtSpeedLabel(prefs.downloadSpeedLimit, l10n)),
            value: _downloadSpeedDraft ??
                (prefs.downloadSpeedLimit / (1024 * 1024)).toDouble(),
            min: 0,
            max: 20,
            divisions: 40,
            label: _downloadSpeedDraft != null &&
                    _downloadSpeedDraft! <= 0
                ? l10n.settingsSpeedUnlimitedLabel
                : l10n.settingsSpeedMbps(((_downloadSpeedDraft ??
                        prefs.downloadSpeedLimit /
                            (1024 * 1024)))
                    .toStringAsFixed(1)),
            width: 160,
            onChanged: (v) =>
                setState(() => _downloadSpeedDraft = v),
            onChangeEnd: (v) {
              setState(() => _downloadSpeedDraft = null);
              ref
                  .read(appPrefsProvider.notifier)
                  .setDownload(speedLimit: (v * 1024 * 1024).round());
            },
          ),
        ], note: l10n.settingsSpeedNote),
        const SizedBox(height: 20),
        _section(scheme, l10n.settingsSectionHistory, [
          _sliderTile(
            Icons.history_outlined,
            l10n.settingsDownloadHistoryLimit,
            l10n.settingsDownloadHistoryDesc(prefs.downloadHistoryLimit),
            value: _downloadHistoryLimitDraft ??
                prefs.downloadHistoryLimit.toDouble(),
            min: 10,
            max: 500,
            divisions: 49,
            label: l10n.settingsDownloadHistoryCount((_downloadHistoryLimitDraft ??
                prefs.downloadHistoryLimit.toDouble()).round()),
            width: 160,
            onChanged: (v) =>
                setState(() => _downloadHistoryLimitDraft = v),
            onChangeEnd: (v) {
              setState(() => _downloadHistoryLimitDraft = null);
              ref
                  .read(appPrefsProvider.notifier)
                  .setDownload(historyLimit: v.round());
            },
          ),
        ], note: l10n.settingsDownloadHistoryNote),
        const SizedBox(height: 8),
        _noteText(scheme, l10n.settingsGroupingNote),
      ],
    );
  }

  void _saveDownloadRoot(String raw, AppLocalizations l10n) {
    final path = raw.trim();
    if (path.isEmpty) {
      toast(l10n.toastDownloadRootEmpty);
      return;
    }
    ref.read(appPrefsProvider.notifier).setDownload(rootDir: path);
    if (!mounted) return;
    toast(l10n.toastDownloadRootUpdated);
  }

  void _saveDownloadTemplate(String raw, AppLocalizations l10n) {
    final template = raw.trim();
    if (template.isEmpty) {
      toast(l10n.toastTemplateEmpty);
      return;
    }
    ref.read(appPrefsProvider.notifier).setDownload(filenameTemplate: template);
    if (!mounted) return;
    toast(l10n.toastTemplateUpdated);
  }

  String _fmtSpeedLabel(int bytesPerSec, AppLocalizations l10n) {
    if (bytesPerSec < 1024) return l10n.settingsSpeedBs(bytesPerSec);
    final kb = bytesPerSec / 1024;
    if (kb < 1024) return l10n.settingsSpeedKbs(kb.toStringAsFixed(0));
    return l10n.settingsSpeedMbs((kb / 1024).toStringAsFixed(1));
  }

  // ── 刮削设置 ──────────────────────────────────────────────

  /// 刮削设置页：目录（留空跟随媒体库扫描目录）+ 数据源开关 +
  /// 进度统计 + 立即刮削/取消（对齐 SPlayer-Next 刮削器多源方案）。
  Widget _buildScrape(ColorScheme scheme, AppLocalizations l10n) {
    final prefs = ref.watch(appPrefsProvider);
    final notifier = ref.read(appPrefsProvider.notifier);
    final scrape = ref.watch(scrapeControllerProvider);
    final scraper = ref.read(scrapeControllerProvider.notifier);
    final dirs = prefs.scrapeDirs.isNotEmpty ? prefs.scrapeDirs : scanDirs();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _section(scheme, l10n.settingsSectionScrapeDirs, [
          _pathFieldCard(
            scheme,
            l10n,
            icon: Icons.folder_outlined,
            ctrl: _scrapeDirsCtrl,
            hint: l10n.settingsScrapeDirsHint,
            save: (v) => _saveScrapeDirs(v, l10n),
            restoreDefault: () => '',
          ),
        ], note: dirs.isEmpty
            ? l10n.settingsScrapeDirsEmptyNote
            : l10n.settingsScrapeDirsNote(dirs.join(' ; '))),
        const SizedBox(height: 20),
        _section(scheme, l10n.settingsSectionScrapeSources, [
          _switchTile(Icons.public, l10n.settingsScrapeSourceMusicBrainz,
              l10n.settingsScrapeSourceDesc, prefs.scrapeUseMusicBrainz,
              (v) => notifier.setScrape(useMusicBrainz: v)),
          _switchTile(Icons.queue_music, l10n.settingsScrapeSourceDeezer,
              l10n.settingsScrapeSourceDesc, prefs.scrapeUseDeezer,
              (v) => notifier.setScrape(useDeezer: v)),
          _switchTile(Icons.storefront_outlined, l10n.settingsScrapeSourceItunes,
              l10n.settingsScrapeSourceDesc, prefs.scrapeUseItunes,
              (v) => notifier.setScrape(useItunes: v)),
          _switchTile(Icons.music_note_outlined, l10n.settingsScrapeSourceNetease,
              l10n.settingsScrapeSourceDesc, prefs.scrapeUseNetease,
              (v) => notifier.setScrape(useNetease: v)),
          _switchTile(Icons.library_music_outlined, l10n.settingsScrapeSourceQQMusic,
              l10n.settingsScrapeSourceDesc, prefs.scrapeUseQQMusic,
              (v) => notifier.setScrape(useQQMusic: v)),
          _switchTile(Icons.headphones_outlined, l10n.settingsScrapeSourceKugou,
              l10n.settingsScrapeSourceDesc, prefs.scrapeUseKugou,
              (v) => notifier.setScrape(useKugou: v)),
          _switchTile(Icons.graphic_eq_outlined, l10n.settingsScrapeSourceKuwo,
              l10n.settingsScrapeSourceDesc, prefs.scrapeUseKuwo,
              (v) => notifier.setScrape(useKuwo: v)),
          _switchTile(Icons.mobile_screen_share_outlined, l10n.settingsScrapeSourceMigu,
              l10n.settingsScrapeSourceDesc, prefs.scrapeUseMigu,
              (v) => notifier.setScrape(useMigu: v)),
          _switchTile(Icons.fingerprint, l10n.settingsScrapeSourceAcoustID,
              l10n.settingsScrapeSourceDesc, prefs.scrapeUseAcoustID,
              (v) => notifier.setScrape(useAcoustID: v)),
        ]),
        const SizedBox(height: 20),
        _section(scheme, l10n.settingsSectionScrapeProgress, [
          _buildScrapeStatus(scheme, l10n, scrape, dirs.isNotEmpty),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            child: scrape.scraping
                ? SButton(
                    label: l10n.settingsScrapeCancel,
                    icon: Icons.stop,
                    variant: SButtonVariant.error,
                    onPressed: scraper.cancel,
                  )
                : SButton(
                    label: l10n.settingsScrapeStart,
                    icon: Icons.auto_fix_high,
                    variant: SButtonVariant.primary,
                    onPressed: _startScrape,
                  ),
          ),
        ]),
      ],
    );
  }

  /// 刮削进度/结果统计区（运行中 → 进度条 + 当前文件；空闲 → 上次结果）。
  Widget _buildScrapeStatus(ColorScheme scheme, AppLocalizations l10n,
      ScrapeState scrape, bool dirsReady) {
    if (scrape.scraping) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (scrape.percent != null) ...[
              LinearProgressIndicator(
                value: scrape.percent,
                minHeight: 4,
                borderRadius: BorderRadius.circular(2),
              ),
              const SizedBox(height: 10),
            ],
            Text(
              scrape.current.isEmpty
                  ? l10n.settingsScrapeScanning
                  : l10n.settingsScrapeCurrent(scrape.current),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 10),
            Wrap(spacing: 14, runSpacing: 4, children: [
              _statChip(
                  scheme, scheme.primary, l10n.settingsScrapeSuccess, scrape.success),
              _statChip(scheme, scheme.error, l10n.settingsScrapeFailed, scrape.failed),
              _statChip(
                  scheme, scheme.onSurfaceVariant, l10n.settingsScrapeSkipped, scrape.skipped),
              _statChip(
                  scheme, scheme.tertiary, l10n.settingsScrapeNotFound, scrape.notFound),
            ]),
          ],
        ),
      );
    }
    if (scrape.hasActivity) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              scrape.error != null
                  ? scrape.error!
                  : scrape.canceled
                      ? l10n.settingsScrapeCanceled
                      : l10n.settingsScrapeDone,
              style: TextStyle(
                fontSize: 12.5,
                color: scrape.error != null
                    ? scheme.error
                    : scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(spacing: 14, runSpacing: 4, children: [
              _statChip(
                  scheme, scheme.primary, l10n.settingsScrapeSuccess, scrape.success),
              _statChip(scheme, scheme.error, l10n.settingsScrapeFailed, scrape.failed),
              _statChip(
                  scheme, scheme.onSurfaceVariant, l10n.settingsScrapeSkipped, scrape.skipped),
              _statChip(
                  scheme, scheme.tertiary, l10n.settingsScrapeNotFound, scrape.notFound),
            ]),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
      child: Text(
        dirsReady ? l10n.settingsScrapeIdle : l10n.settingsScrapeNoDirs,
        style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
      ),
    );
  }

  Widget _statChip(ColorScheme scheme, Color color, String label, int value) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      const SizedBox(width: 5),
      Text(
        '$label $value',
        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
      ),
    ]);
  }

  void _startScrape() {
    final l10n = context.l10n;
    final prefs = ref.read(appPrefsProvider);
    var dirs = prefs.scrapeDirs;
    if (dirs.isEmpty) dirs = scanDirs();
    if (dirs.isEmpty) {
      toast(l10n.toastScrapeNoDirs);
      return;
    }
    ref.read(scrapeControllerProvider.notifier).start(
          dirs: dirs,
          dbPath: '${resolveDataDir()}/scraper-state.db',
          sources: ScrapeSources(
            musicBrainz: prefs.scrapeUseMusicBrainz,
            deezer: prefs.scrapeUseDeezer,
            itunes: prefs.scrapeUseItunes,
            netease: prefs.scrapeUseNetease,
            qqMusic: prefs.scrapeUseQQMusic,
            kugou: prefs.scrapeUseKugou,
            kuwo: prefs.scrapeUseKuwo,
            migu: prefs.scrapeUseMigu,
            acoustId: prefs.scrapeUseAcoustID,
          ),
        );
  }

  void _saveScrapeDirs(String raw, AppLocalizations l10n) {
    final dirs = raw
        .split('\n')
        .map((d) => d.trim())
        .where((d) => d.isNotEmpty)
        .toList();
    ref.read(appPrefsProvider.notifier).setScrape(dirs: dirs);
    if (!mounted) return;
    toast(l10n.toastScrapeDirsUpdated);
  }

  Widget _buildStorage(ColorScheme scheme, AppLocalizations l10n) {
    final dataDir = resolveDataDir();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _section(scheme, l10n.settingsSectionFileLocation, [
          _SettingTile(
            icon: Icons.folder_outlined,
            title: l10n.settingsDataDir,
            subtitle: dataDir,
            trailing: _copyButton(dataDir, l10n.settingsDataDir, l10n),
          ),
          _SettingTile(
            icon: Icons.album_outlined,
            title: l10n.settingsLibraryDb,
            subtitle: '$dataDir/database/library.db',
            trailing: _copyButton('$dataDir/database/library.db', l10n.settingsLibraryDbLabel, l10n),
          ),
          _SettingTile(
            icon: Icons.key_outlined,
            title: l10n.settingsUserDb,
            subtitle: '$dataDir/database/user.db',
            trailing: _copyButton('$dataDir/database/user.db', l10n.settingsUserDbLabel, l10n),
          ),
        ], note: l10n.settingsStorageNote),
      ],
    );
  }

  Widget _buildAbout(ColorScheme scheme, AppLocalizations l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _section(scheme, l10n.appName, [
          // 长按「版本」10 秒开启开发者模式（隐藏下载接口的入口）。
          // Listener 对鼠标按住 / 触摸长按通用；悬浮弹提示 + 进度条反馈。
          Listener(
            onPointerDown: (_) => _startDevHold(),
            onPointerUp: (_) => _cancelDevHold(),
            onPointerCancel: (_) => _cancelDevHold(),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Tooltip(
                message: l10n.settingsDeveloperHoldHint,
                waitDuration: const Duration(seconds: 1),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _SettingTile(
                      icon: Icons.music_note_outlined,
                      title: l10n.settingsVersion,
                      subtitle: _version.isEmpty
                          ? l10n.settingsVersionUnknown
                          : l10n.settingsVersionFormat(_version),
                      trailing: const SizedBox.shrink(),
                    ),
                    if (_devHolding)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: _devHoldProgress,
                            minHeight: 3,
                            backgroundColor:
                                scheme.primary.withValues(alpha: 0.12),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          _SettingTile(
            icon: Icons.memory_outlined,
            title: l10n.settingsAudioEngine,
            subtitle: l10n.settingsAudioEngineDesc,
            trailing: const SizedBox.shrink(),
          ),
          _SettingTile(
            icon: Icons.dns_outlined,
            title: l10n.settingsSubsonicServer,
            subtitle: l10n.settingsSubsonicDesc,
            trailing: const SizedBox.shrink(),
          ),
        ], note: l10n.settingsAboutDesc),
        const SizedBox(height: 12),
        _section(scheme, l10n.settingsSectionFontCredits, [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Text(
              l10n.settingsFontCreditsText,
              style: TextStyle(
                fontSize: 12,
                height: 1.6,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
              ),
            ),
          ),
        ]),
        const SizedBox(height: 12),
        _section(scheme, l10n.settingsSectionDeclaration, [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Text.rich(
              TextSpan(
                style: TextStyle(
                  fontSize: 12,
                  height: 1.6,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
                ),
                children: [
                  TextSpan(text: l10n.settingsDeclineText),
                  _dense(l10n.settingsDecline1Title, l10n.settingsDecline1Body),
                  _dense(l10n.settingsDecline2Title, l10n.settingsDecline2Body),
                  _dense(l10n.settingsDecline3Title, l10n.settingsDecline3Body),
                  _dense(l10n.settingsDecline4Title, l10n.settingsDecline4Body),
                  _dense(l10n.settingsDecline5Title, l10n.settingsDecline5Body),
                  TextSpan(text: l10n.settingsDeclineFooter),
                ],
              ),
            ),
          ),
        ]),
      ],
    );
  }

  TextSpan _dense(String title, String body) {
    return TextSpan(
      children: [
        TextSpan(
          text: title,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        TextSpan(text: body),
      ],
    );
  }

  /// 开发者分类：开发者模式开关 + 隐藏的下载接口说明。
  /// 仅在开发者模式开启后可从设置导航进入（关闭后本分类一并隐藏）。
  Widget _buildDeveloper(ColorScheme scheme, AppLocalizations l10n) {
    final devMode = ref.watch(appPrefsProvider).developerMode;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _section(scheme, l10n.settingsDeveloperTitle, [
          _SettingTile(
            icon: Icons.engineering_outlined,
            title: l10n.settingsDeveloperMode,
            subtitle: devMode
                ? l10n.settingsDeveloperModeOn
                : l10n.settingsDeveloperModeOff,
            trailing: Switch(
              value: devMode,
              onChanged: (v) {
                ref.read(appPrefsProvider.notifier).setDeveloperMode(v);
                toast(v ? l10n.settingsDeveloperEnabled : l10n.settingsDeveloperDisabled,
                    type: v ? ToastType.success : ToastType.info);
                if (!v && mounted) {
                  // 关闭后分类不可达 → 退回关于页
                  setState(() => _category = SettingsCategory.about);
                }
              },
            ),
          ),
          _SettingTile(
            icon: Icons.download_outlined,
            title: l10n.settingsDeveloperDownloadModule,
            subtitle: l10n.settingsDeveloperDownloadModuleDesc,
            trailing: const SizedBox.shrink(),
          ),
        ], note: l10n.settingsDeveloperNote),
      ],
    );
  }

  Widget _sectionTitle(ColorScheme scheme, String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
          color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
        ),
      ),
    );
  }

  Widget _card(ColorScheme scheme, {required List<Widget> children}) {
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: scheme.outline.withValues(alpha: 0.3)),
      ),
      child: Column(children: children),
    );
  }

  Widget _copyButton(String value, String label, AppLocalizations l10n) {
    return SizedBox(
      height: 28,
      child: SButton(
        label: l10n.settingsCopy,
        variant: SButtonVariant.ghost,
        size: SButtonSize.small,
        onPressed: () async {
          await Clipboard.setData(ClipboardData(text: value));
          if (!mounted) return;
          toast(l10n.toastCopied(label),
              type: ToastType.success, duration: const Duration(milliseconds: 1200));
        },
      ),
    );
  }

  /// 灰色说明文字（设置项下方的灰色 note）。
  Widget _noteText(ColorScheme scheme, String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
      ),
    );
  }

  /// 设置行 + 右侧开关。
  Widget _switchTile(
    IconData icon,
    String title,
    String subtitle,
    bool value,
    ValueChanged<bool>? onChanged, {
    bool enabled = true,
  }) {
    return _SettingTile(
      icon: icon,
      title: title,
      subtitle: subtitle,
      enabled: enabled,
      trailing: Switch(
        value: value,
        onChanged: enabled ? onChanged : null,
      ),
    );
  }

  /// 设置行 + 右侧滑块。
  Widget _sliderTile(
    IconData icon,
    String title,
    String subtitle, {
    required double value,
    required double min,
    required double max,
    int? divisions,
    String? label,
    double width = 140,
    ValueChanged<double>? onChangeEnd,
    required ValueChanged<double> onChanged,
  }) {
    return _SettingTile(
      icon: icon,
      title: title,
      subtitle: subtitle,
      trailing: SizedBox(
        width: width,
        child: Slider(
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          label: label,
          onChangeEnd: onChangeEnd,
          onChanged: onChanged,
        ),
      ),
    );
  }

  /// 设置分区：小标题 + 卡片（可选底部灰色说明）。
  Widget _section(
    ColorScheme scheme,
    String title,
    List<Widget> children, {
    String? note,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle(scheme, title),
        _card(scheme, children: children),
        if (note != null) ...[
          const SizedBox(height: 8),
          _noteText(scheme, note),
        ],
      ],
    );
  }

  /// 下载路径输入卡：图标徽章 + 输入框 + 恢复默认（下载目录 / 文件名模板共用）。
  Widget _pathFieldCard(
    ColorScheme scheme,
    AppLocalizations l10n, {
    required IconData icon,
    required TextEditingController ctrl,
    required String hint,
    required void Function(String) save,
    required String Function() restoreDefault,
  }) {
    return _card(
      scheme,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(icon, size: 18, color: scheme.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: ctrl,
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    hintText: hint,
                    isDense: true,
                    border: InputBorder.none,
                  ),
                  onSubmitted: (v) => save(v),
                ),
              ),
              TextButton(
                onPressed: () {
                  final def = restoreDefault();
                  ctrl.text = def;
                  save(def);
                },
                child: Text(l10n.settingsRestoreDefault),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SettingTile extends StatelessWidget {
  const _SettingTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.trailing,
    this.enabled = true,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget trailing;

  /// 禁用时整行变灰（图标/标题/副标题降透明度），配合右侧控件禁用。
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = enabled
        ? scheme.primary
        : scheme.primary.withValues(alpha: 0.35);
    final textFg = enabled
        ? scheme.onSurface
        : scheme.onSurface.withValues(alpha: 0.38);
    final subFg = enabled
        ? scheme.onSurfaceVariant.withValues(alpha: 0.75)
        : scheme.onSurfaceVariant.withValues(alpha: 0.35);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: fg.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(icon, size: 18, color: fg),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: textFg,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: subFg,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          trailing,
        ],
      ),
    );
  }
}

class _AccentPickerDialog extends StatefulWidget {
  const _AccentPickerDialog({required this.initial, required this.l10n});
  final Color initial;
  final AppLocalizations l10n;

  @override
  State<_AccentPickerDialog> createState() => _AccentPickerDialogState();
}

class _AccentPickerDialogState extends State<_AccentPickerDialog> {
  late HSVColor _hsv;
  late final TextEditingController _hexCtrl;

  @override
  void initState() {
    super.initState();
    _hsv = HSVColor.fromColor(widget.initial);
    _hexCtrl = TextEditingController(text: _hexOf(widget.initial));
  }

  @override
  void dispose() {
    _hexCtrl.dispose();
    super.dispose();
  }

  static String _hexOf(Color c) {
    final v = c.toARGB32() & 0xFFFFFF;
    return '#${v.toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }

  void _setHsv(HSVColor v) {
    setState(() {
      _hsv = v;
      _hexCtrl.text = _hexOf(v.toColor());
    });
  }

  void _applyHex(String raw) {
    final s = raw.trim().replaceFirst('#', '');
    if (s.length != 6) return;
    final v = int.tryParse(s, radix: 16);
    if (v == null) return;
    setState(() {
      _hsv = HSVColor.fromColor(Color(0xFF000000 | v));
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = widget.l10n;
    final color = _hsv.toColor();
    // Dialog 透明根 + GlassDialogSurface 只包内容（对齐 SDialog）：
    // AlertDialog 自身就是 Dialog，再嵌套进外层 Dialog 会布局异常全屏；
    // GlassDialogSurface 若直接作 showDialog 根则会铺满窗口成「全遮罩」。
    return Dialog(
      insetPadding: const EdgeInsets.all(48),
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
      ),
      clipBehavior: Clip.antiAlias,
      child: GlassDialogSurface(
        radius: BorderRadius.circular(24),
        color: scheme.surfaceContainerHighest,
        child: SizedBox(
          width: 320,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  l10n.settingsPickerTitle,
                  style: Theme.of(context).dialogTheme.titleTextStyle,
                ),
                const SizedBox(height: 16),
                _SvPanel(hsv: _hsv, onChanged: _setHsv),
                const SizedBox(height: 8),
                Slider(
                  value: _hsv.hue,
                  min: 0,
                  max: 360,
                  onChanged: (h) => _setHsv(_hsv.withHue(h)),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: color,
                        border: Border.all(
                          color:
                              theme.colorScheme.outline.withValues(alpha: 0.6),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _hexCtrl,
                        onChanged: _applyHex,
                        decoration: InputDecoration(
                          labelText: l10n.settingsPickerHexLabel,
                          isDense: true,
                        ),
                        textInputAction: TextInputAction.done,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(l10n.commonCancel),
                    ),
                    const SizedBox(width: 10),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, color),
                      child: Text(l10n.settingsApply),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SvPanel extends StatelessWidget {
  const _SvPanel({required this.hsv, required this.onChanged});
  final HSVColor hsv;
  final ValueChanged<HSVColor> onChanged;

  @override
  Widget build(BuildContext context) {
    final base = HSVColor.fromAHSV(1, hsv.hue, 1, 1).toColor();
    return AspectRatio(
      aspectRatio: 2,
      child: LayoutBuilder(
        builder: (context, c) {
          final size = Size(c.maxWidth, c.maxHeight);
          return GestureDetector(
            onPanDown: (d) => _pick(d.localPosition, size),
            onPanUpdate: (d) => _pick(d.localPosition, size),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Colors.white, base],
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                      ),
                    ),
                  ),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Colors.transparent, Colors.black],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                      ),
                    ),
                  ),
                  Positioned(
                    left: hsv.saturation * c.maxWidth - 7,
                    top: (1 - hsv.value) * c.maxHeight - 7,
                    child: Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.4),
                            blurRadius: 3,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _pick(Offset pos, Size size) {
    final s = (pos.dx / size.width).clamp(0.0, 1.0);
    final v = (1 - pos.dy / size.height).clamp(0.0, 1.0);
    onChanged(hsv.withSaturation(s).withValue(v));
  }
}
