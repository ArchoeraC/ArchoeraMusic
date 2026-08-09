/// 全局设置弹窗（对齐原项目 SettingsDialog：左侧分类菜单 + 右侧内容区）。
library;

import 'dart:io' show File;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/playback/playback_notifier.dart';
import '../../core/state/app_prefs.dart';
import '../../core/state/data_dir.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import '../app.dart';
import '../theme/app_theme.dart';
import '../widgets/s_controls.dart';
import '../widgets/toast.dart';
import 'streaming_server_list.dart';

void showSettingsDialog(BuildContext context, {SettingsCategory? category}) {
  showDialog<void>(
    context: context,
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
  mediaSource(Icons.dns_outlined),
  about(Icons.info_outline);

  const SettingsCategory(this.icon);
  final IconData icon;

  String label(AppLocalizations l10n) => switch (this) {
        appearance => l10n.settingsCatAppearance,
        playback => l10n.settingsCatPlayback,
        lyrics => l10n.settingsCatLyrics,
        preset => l10n.settingsCatPreset,
        download => l10n.settingsCatDownload,
        storage => l10n.settingsCatStorage,
        mediaSource => l10n.settingsCatMediaSource,
        about => l10n.settingsCatAbout,
      };

  String subtitle(AppLocalizations l10n) => switch (this) {
        appearance => l10n.settingsAppearanceSubtitle,
        playback => l10n.settingsPlaybackSubtitle,
        lyrics => l10n.settingsLyricsSubtitle,
        preset => l10n.settingsPresetSubtitle,
        download => l10n.settingsDownloadSubtitle,
        storage => l10n.settingsStorageSubtitle,
        mediaSource => l10n.settingsMediaSourceSubtitle,
        about => l10n.settingsAboutSubtitle,
      };
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
  double? _downloadConcurrentDraft;
  double? _downloadSpeedDraft;
  double? _downloadHistoryLimitDraft;

  @override
  void initState() {
    super.initState();
    _loadVersion();
    _downloadRootCtrl =
        TextEditingController(text: ref.read(appPrefsProvider).downloadRoot);
    _downloadTemplateCtrl = TextEditingController(
        text: ref.read(appPrefsProvider).downloadFilenameTemplate);
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

  @override
  void dispose() {
    _searchCtrl.dispose();
    _downloadRootCtrl.dispose();
    _downloadTemplateCtrl.dispose();
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
      _SearchEntry(SettingsCategory.lyrics, l10n.settingsLyricFontSize, l10n.settingsSearchLyricFontSizeSubtitle, Icons.format_size),
      _SearchEntry(SettingsCategory.lyrics, l10n.settingsLyricLineHeight, l10n.settingsSearchLyricLineHeightSubtitle, Icons.line_weight),
      _SearchEntry(SettingsCategory.lyrics, l10n.settingsSearchColorTitle, l10n.settingsSearchColorSubtitle, Icons.palette_outlined),
      _SearchEntry(SettingsCategory.lyrics, l10n.settingsSearchDesktopLyricsTitle, l10n.settingsSearchDesktopLyricsSubtitle, Icons.desktop_windows_outlined),
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
      _SearchEntry(SettingsCategory.mediaSource, l10n.settingsCatMediaSource, l10n.settingsMediaSourceSubtitle, Icons.dns_outlined),
      _SearchEntry(SettingsCategory.about, l10n.settingsVersion, l10n.settingsSearchAboutSubtitle, Icons.info_outline),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;
    final window = MediaQuery.sizeOf(context);
    return Dialog(
      backgroundColor: scheme.surfaceContainerHighest,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.dialog),
        side: BorderSide(color: scheme.outline.withValues(alpha: 0.5)),
      ),
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
                      child: ListView(
                        padding: EdgeInsets.zero,
                        children: [
                          for (final cat in SettingsCategory.values)
                            _buildCategoryItem(scheme, cat, l10n),
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
    );
  }

  Widget _buildCategoryItem(ColorScheme scheme, SettingsCategory cat, AppLocalizations l10n) {
    final selected = _category == cat;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
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
                  Positioned(
                    left: 0,
                    top: 10,
                    bottom: 10,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      width: 3,
                      decoration: BoxDecoration(
                        color: selected
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
                SettingsCategory.mediaSource =>
                  StreamingServerList(),
                SettingsCategory.about => _buildAbout(scheme, l10n),
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
    final index = _buildSearchIndex(l10n);
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
            if (matches.any((e) => e.category == cat)) ...[
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
        _sectionTitle(scheme, l10n.settingsSectionTheme),
        _card(
          scheme,
          children: [
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
          ],
        ),
        const SizedBox(height: 8),
        Text(
          l10n.settingsThemeNote,
          style: TextStyle(
            fontSize: 12,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
          ),
        ),
        const SizedBox(height: 20),

        // 主题色来源（default / custom / cover / solid）
        _sectionTitle(scheme, l10n.settingsSectionAccent),
        _card(
          scheme,
          children: [
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
          ],
        ),
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
          Text(
            l10n.settingsThemeSourceCoverHint,
            style: TextStyle(
              fontSize: 12,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
          ),
        ],
        const SizedBox(height: 12),

        // 全局着色
        _card(
          scheme,
          children: [
            _SettingTile(
              icon: Icons.tonality_outlined,
              title: l10n.settingsGlobalTint,
              subtitle: l10n.settingsGlobalTintDesc,
              trailing: Switch(
                value: prefs.globalTint,
                onChanged: (v) => notifier.setGlobalTint(v),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          l10n.settingsGlobalTintNote,
          style: TextStyle(
            fontSize: 12,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
          ),
        ),
        const SizedBox(height: 20),

        // ── 外观风格（纯色 / 图片背景）──
        _sectionTitle(scheme, l10n.settingsSectionStyle),
        _card(
          scheme,
          children: [
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
          ],
        ),
        if (prefs.appearanceStyle == 'image') ...[
          const SizedBox(height: 8),
          _backgroundCard(scheme, prefs, l10n, notifier),
          if (imageStyle) ...[
            const SizedBox(height: 12),
            _card(
              scheme,
              children: [
                _SettingTile(
                  icon: Icons.blur_on_outlined,
                  title: l10n.settingsBackgroundBlur,
                  subtitle:
                      l10n.settingsBackgroundBlurDesc(prefs.backgroundBlur),
                  trailing: SizedBox(
                    width: 140,
                    child: Slider(
                      value: prefs.backgroundBlur.toDouble(),
                      min: 0,
                      max: 80,
                      divisions: 16,
                      label: '${prefs.backgroundBlur}px',
                      onChanged: (v) =>
                          notifier.setBackground(blur: v.round()),
                    ),
                  ),
                ),
                _SettingTile(
                  icon: Icons.dark_mode_outlined,
                  title: l10n.settingsBackgroundDim,
                  subtitle:
                      l10n.settingsBackgroundDimDesc(prefs.backgroundDim),
                  trailing: SizedBox(
                    width: 140,
                    child: Slider(
                      value: prefs.backgroundDim,
                      min: 0.3,
                      max: 0.9,
                      divisions: 12,
                      label: '${(prefs.backgroundDim * 100).round()}%',
                      onChanged: (v) => notifier.setBackground(dim: v),
                    ),
                  ),
                ),
                _SettingTile(
                  icon: Icons.zoom_out_map_outlined,
                  title: l10n.settingsBackgroundScale,
                  subtitle:
                      l10n.settingsBackgroundScaleDesc(prefs.backgroundScale),
                  trailing: SizedBox(
                    width: 140,
                    child: Slider(
                      value: prefs.backgroundScale,
                      min: 1,
                      max: 2,
                      divisions: 20,
                      label: '${prefs.backgroundScale.toStringAsFixed(1)}x',
                      onChanged: (v) => notifier.setBackground(scale: v),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
        const SizedBox(height: 20),

        // ── 布局 ──
        _sectionTitle(scheme, l10n.settingsSectionLayout),
        _card(
          scheme,
          children: [
            _SettingTile(
              icon: Icons.rounded_corner,
              title: l10n.settingsFloatingBar,
              subtitle: prefs.floatingPlayerBar
                  ? l10n.settingsFloatingBarOn
                  : l10n.settingsFloatingBarOff,
              trailing: Switch(
                value: prefs.floatingPlayerBar,
                onChanged: (value) => notifier.setFloatingPlayerBar(value),
              ),
            ),
            _SettingTile(
              icon: prefs.sidebarCollapsed
                  ? Icons.menu_open
                  : Icons.menu_rounded,
              title: l10n.settingsSidebarCollapsed,
              subtitle: l10n.settingsSidebarCollapsedDesc,
              trailing: Switch(
                value: prefs.sidebarCollapsed,
                onChanged: (value) => notifier.setSidebar(collapsed: value),
              ),
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
          ],
        ),
        const SizedBox(height: 20),

        // ── 字体 ──
        _sectionTitle(scheme, l10n.settingsSectionFont),
        _card(
          scheme,
          children: [
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
          ],
        ),
        const SizedBox(height: 20),

        // ── 语言 ──
        _sectionTitle(scheme, l10n.settingsSectionLanguage),
        _card(
          scheme,
          children: [
            _SettingTile(
              icon: Icons.language_outlined,
              title: l10n.settingsLanguageTitle,
              subtitle: l10n.settingsLanguageDesc,
              trailing: _languageDropdown(scheme, prefs.locale, l10n),
            ),
          ],
        ),
        const SizedBox(height: 20),

        // ── 封面圆角 ──
        _sectionTitle(scheme, l10n.settingsSectionCover),
        _card(
          scheme,
          children: [
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
          ],
        ),
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
        _sectionTitle(scheme, l10n.settingsSectionAudio),
        _card(
          scheme,
          children: [
            _SettingTile(
              icon: prefs.passthrough
                  ? Icons.high_quality_outlined
                  : Icons.transform_rounded,
              title: l10n.settingsPassthrough,
              subtitle: prefs.passthrough
                  ? l10n.settingsPassthroughOn
                  : l10n.settingsPassthroughOff,
              trailing: Switch(
                value: prefs.passthrough,
                onChanged: (value) {
                  ref.read(appPrefsProvider.notifier).setPassthrough(value);
                  ref.read(playbackProvider.notifier).reload();
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          l10n.settingsPassthroughNote,
          style: TextStyle(
            fontSize: 12,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
          ),
        ),
        const SizedBox(height: 20),
        _sectionTitle(scheme, l10n.settingsSectionMemory),
        _card(
          scheme,
          children: [
            _SettingTile(
              icon: prefs.sessionMemory ? Icons.history : Icons.history_toggle_off,
              title: l10n.settingsSessionMemory,
              subtitle: prefs.sessionMemory
                  ? l10n.settingsSessionMemoryOn
                  : l10n.settingsSessionMemoryOff,
              trailing: Switch(
                value: prefs.sessionMemory,
                onChanged: (value) =>
                    ref.read(appPrefsProvider.notifier).setMemoryEnabled(value),
              ),
            ),
            _SettingTile(
              icon: prefs.autoPlayOnLaunch
                  ? Icons.play_circle_outline
                  : Icons.pause_circle_outline,
              title: l10n.settingsAutoPlay,
              subtitle: !prefs.sessionMemory
                  ? l10n.settingsAutoPlayNeedMemory
                  : prefs.autoPlayOnLaunch
                      ? l10n.settingsAutoPlayOn
                      : l10n.settingsAutoPlayOff,
              trailing: Switch(
                value: prefs.sessionMemory && prefs.autoPlayOnLaunch,
                onChanged: prefs.sessionMemory
                    ? (value) => ref
                        .read(appPrefsProvider.notifier)
                        .setAutoPlayOnLaunch(value)
                    : null,
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        _sectionTitle(scheme, l10n.settingsSectionClose),
        _card(
          scheme,
          children: [
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
          ],
        ),
        const SizedBox(height: 20),
        _sectionTitle(scheme, l10n.settingsSectionSpectrum),
        _card(
          scheme,
          children: [
            _SettingTile(
              icon: prefs.enableSpectrum
                  ? Icons.graphic_eq
                  : Icons.graphic_eq_outlined,
              title: l10n.settingsSpectrum,
              subtitle: prefs.enableSpectrum
                  ? l10n.settingsSpectrumOn
                  : l10n.settingsSpectrumOff,
              trailing: Switch(
                value: prefs.enableSpectrum,
                onChanged: (value) => ref
                    .read(appPrefsProvider.notifier)
                    .setSpectrumEnabled(value),
              ),
            ),
            _SettingTile(
              icon: Icons.view_column_outlined,
              title: l10n.settingsSpectrumBarWidth,
              subtitle: l10n.settingsSpectrumBarWidthDesc(prefs.spectrumBarWidth),
              trailing: SizedBox(
                width: 140,
                child: Slider(
                  value: prefs.spectrumBarWidth.toDouble(),
                  min: 1,
                  max: 12,
                  divisions: 11,
                  label: '${prefs.spectrumBarWidth}px',
                  onChanged: (v) => ref
                      .read(appPrefsProvider.notifier)
                      .setSpectrumBarWidth(v.round()),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        _sectionTitle(scheme, l10n.settingsTransitionStyle),
        _card(
          scheme,
          children: [
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
          ],
        ),
        const SizedBox(height: 20),
        _sectionTitle(scheme, l10n.settingsSectionShortcuts),
        _card(
          scheme,
          children: [
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
          ],
        ),
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
        _sectionTitle(scheme, l10n.settingsSectionPlayerLyrics),
        _card(
          scheme,
          children: [
            _SettingTile(
              icon: prefs.showLyricsInPlayer
                  ? Icons.lyrics_outlined
                  : Icons.lyrics,
              title: l10n.settingsPlayerLyrics,
              subtitle: prefs.showLyricsInPlayer
                  ? l10n.settingsPlayerLyricsOn
                  : l10n.settingsPlayerLyricsOff,
              trailing: Switch(
                value: prefs.showLyricsInPlayer,
                onChanged: (value) => ref
                    .read(appPrefsProvider.notifier)
                    .setShowLyricsInPlayer(value),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        _sectionTitle(scheme, l10n.settingsSectionLyricStyle),
        _card(
          scheme,
          children: [
            _SettingTile(
              icon: Icons.format_size,
              title: l10n.settingsLyricFontSize,
              subtitle: l10n.settingsLyricFontSizeDesc(prefs.lyricFontSize.round()),
              trailing: SizedBox(
                width: 140,
                child: Slider(
                  value: prefs.lyricFontSize,
                  min: 14,
                  max: 28,
                  divisions: 14,
                  label: '${prefs.lyricFontSize.round()}px',
                  onChanged: (v) => ref
                      .read(appPrefsProvider.notifier)
                      .setLyricStyle(fontSize: v),
                ),
              ),
            ),
            _SettingTile(
              icon: Icons.line_weight,
              title: l10n.settingsLyricLineHeight,
              subtitle: l10n.settingsLyricLineHeightDesc(prefs.lyricLineHeight.round()),
              trailing: SizedBox(
                width: 140,
                child: Slider(
                  value: prefs.lyricLineHeight,
                  min: 42,
                  max: 64,
                  divisions: 11,
                  label: '${prefs.lyricLineHeight.round()}px',
                  onChanged: (v) => ref
                      .read(appPrefsProvider.notifier)
                      .setLyricStyle(lineHeight: v),
                ),
              ),
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
          ],
        ),
        const SizedBox(height: 8),
        Text(
          l10n.settingsLyricsNote,
          style: TextStyle(
            fontSize: 12,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
          ),
        ),
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
        _sectionTitle(scheme, l10n.settingsSectionFilter),
        _card(
          scheme,
          children: [
            _SettingTile(
              icon: prefs.fuckDjMode
                  ? Icons.auto_fix_high
                  : Icons.auto_fix_high_outlined,
              title: 'Fuck DJ Mode',
              subtitle: prefs.fuckDjMode
                  ? l10n.settingsDjModeOn
                  : l10n.settingsDjModeOff,
              trailing: Switch(
                value: prefs.fuckDjMode,
                onChanged: (v) => notifier.setPreset(fuckDjMode: v),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          l10n.settingsDjModeNote,
          style: TextStyle(
            fontSize: 12,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
          ),
        ),
        const SizedBox(height: 20),
        _sectionTitle(scheme, l10n.settingsSectionLyricsFilter),
        _card(
          scheme,
          children: [
            _SettingTile(
              icon: prefs.uncensorProfanity
                  ? Icons.auto_fix_normal
                  : Icons.auto_fix_normal_outlined,
              title: l10n.settingsUncensor,
              subtitle: prefs.uncensorProfanity
                  ? l10n.settingsUncensorOn
                  : l10n.settingsUncensorOff,
              trailing: Switch(
                value: prefs.uncensorProfanity,
                onChanged: (v) => notifier.setPreset(uncensorProfanity: v),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        _sectionTitle(scheme, l10n.settingsSectionListDisplay),
        _card(
          scheme,
          children: [
            _SettingTile(
              icon: Icons.workspace_premium_outlined,
              title: l10n.settingsHideVip,
              subtitle: prefs.hideVipTag
                  ? l10n.settingsHideVipOn
                  : l10n.settingsHideVipOff,
              trailing: Switch(
                value: prefs.hideVipTag,
                onChanged: (v) => notifier.setPreset(hideVipTag: v),
              ),
            ),
            _SettingTile(
              icon: Icons.high_quality_outlined,
              title: l10n.settingsHideQuality,
              subtitle: prefs.hideQualityTag
                  ? l10n.settingsHideQualityOn
                  : l10n.settingsHideQualityOff,
              trailing: Switch(
                value: prefs.hideQualityTag,
                onChanged: (v) => notifier.setPreset(hideQualityTag: v),
              ),
            ),
            _SettingTile(
              icon: prefs.showSubtitle
                  ? Icons.subtitles
                  : Icons.subtitles_off_outlined,
              title: l10n.settingsShowSubtitle,
              subtitle: prefs.showSubtitle
                  ? l10n.settingsShowSubtitleOn
                  : l10n.settingsShowSubtitleOff,
              trailing: Switch(
                value: prefs.showSubtitle,
                onChanged: (v) => notifier.setPreset(showSubtitle: v),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildDownload(ColorScheme scheme, AppLocalizations l10n) {
    final prefs = ref.watch(appPrefsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle(scheme, l10n.settingsSectionDir),
        _card(
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
                    child: Icon(Icons.folder_outlined,
                        size: 18, color: scheme.primary),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _downloadRootCtrl,
                      style: const TextStyle(fontSize: 13),
                      decoration: InputDecoration(
                        hintText: l10n.settingsDownloadRootHint,
                        isDense: true,
                        border: InputBorder.none,
                      ),
                      onSubmitted: (v) => _saveDownloadRoot(v, scheme, l10n),
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      final def = defaultDownloadRoot();
                      _downloadRootCtrl.text = def;
                      _saveDownloadRoot(def, scheme, l10n);
                    },
                    child: Text(l10n.settingsRestoreDefault),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          l10n.settingsDownloadRootNote,
          style: TextStyle(
            fontSize: 12,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
          ),
        ),
        const SizedBox(height: 20),
        _sectionTitle(scheme, l10n.settingsSectionFilename),
        _card(
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
                    child: Icon(Icons.text_fields_outlined,
                        size: 18, color: scheme.primary),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _downloadTemplateCtrl,
                      style: const TextStyle(fontSize: 13),
                      decoration: InputDecoration(
                        hintText: l10n.settingsDownloadTemplateHint,
                        isDense: true,
                        border: InputBorder.none,
                      ),
                      onSubmitted: (v) => _saveDownloadTemplate(v, scheme, l10n),
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      const def = '{artist} - {title}';
                      _downloadTemplateCtrl.text = def;
                      _saveDownloadTemplate(def, scheme, l10n);
                    },
                    child: Text(l10n.settingsRestoreDefault),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          l10n.settingsDownloadTemplateNote,
          style: TextStyle(
            fontSize: 12,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
          ),
        ),
        const SizedBox(height: 20),
        _sectionTitle(scheme, l10n.settingsSectionQuality),
        _card(
          scheme,
          children: [
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
          ],
        ),
        const SizedBox(height: 8),
        Text(
          l10n.settingsDownloadQualityNote,
          style: TextStyle(
            fontSize: 12,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
          ),
        ),
        const SizedBox(height: 20),
        _sectionTitle(scheme, l10n.settingsSectionConcurrent),
        _card(
          scheme,
          children: [
            _SettingTile(
              icon: Icons.speed_outlined,
              title: l10n.settingsDownloadConcurrent,
              subtitle: l10n.settingsDownloadConcurrentDesc(prefs.downloadMaxConcurrent),
              trailing: SizedBox(
                width: 160,
                child: Slider(
                  value:
                      _downloadConcurrentDraft ??
                      prefs.downloadMaxConcurrent.toDouble(),
                  min: 1,
                  max: 5,
                  divisions: 4,
                  label: '${(_downloadConcurrentDraft ??
                      prefs.downloadMaxConcurrent.toDouble()).round()}',
                  onChanged: (v) =>
                      setState(() => _downloadConcurrentDraft = v),
                  onChangeEnd: (v) {
                    setState(() => _downloadConcurrentDraft = null);
                    ref
                        .read(appPrefsProvider.notifier)
                        .setDownload(maxConcurrent: v.round());
                  },
                ),
              ),
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
          ],
        ),
        const SizedBox(height: 20),
        _sectionTitle(scheme, l10n.settingsSectionSpeedLimit),
        _card(
          scheme,
          children: [
            _SettingTile(
              icon: Icons.speed_outlined,
              title: l10n.settingsDownloadSpeedLimit,
              subtitle: prefs.downloadSpeedLimit <= 0
                  ? l10n.settingsSpeedUnlimited
                  : l10n.settingsSpeedLimited(_fmtSpeedLabel(prefs.downloadSpeedLimit, l10n)),
              trailing: SizedBox(
                width: 160,
                child: Slider(
                  value:
                      _downloadSpeedDraft ??
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
                  onChanged: (v) =>
                      setState(() => _downloadSpeedDraft = v),
                  onChangeEnd: (v) {
                    setState(() => _downloadSpeedDraft = null);
                    ref
                        .read(appPrefsProvider.notifier)
                        .setDownload(speedLimit: (v * 1024 * 1024).round());
                  },
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          l10n.settingsSpeedNote,
          style: TextStyle(
            fontSize: 12,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
          ),
        ),
        const SizedBox(height: 20),
        _sectionTitle(scheme, l10n.settingsSectionHistory),
        _card(
          scheme,
          children: [
            _SettingTile(
              icon: Icons.history_outlined,
              title: l10n.settingsDownloadHistoryLimit,
              subtitle: l10n.settingsDownloadHistoryDesc(prefs.downloadHistoryLimit),
              trailing: SizedBox(
                width: 160,
                child: Slider(
                  value: _downloadHistoryLimitDraft ??
                      prefs.downloadHistoryLimit.toDouble(),
                  min: 10,
                  max: 500,
                  divisions: 49,
                  label: l10n.settingsDownloadHistoryCount((_downloadHistoryLimitDraft ??
                      prefs.downloadHistoryLimit.toDouble()).round()),
                  onChanged: (v) =>
                      setState(() => _downloadHistoryLimitDraft = v),
                  onChangeEnd: (v) {
                    setState(() => _downloadHistoryLimitDraft = null);
                    ref
                        .read(appPrefsProvider.notifier)
                        .setDownload(historyLimit: v.round());
                  },
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          l10n.settingsDownloadHistoryNote,
          style: TextStyle(
            fontSize: 12,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          l10n.settingsGroupingNote,
          style: TextStyle(
            fontSize: 12,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
          ),
        ),
      ],
    );
  }

  void _saveDownloadRoot(String raw, ColorScheme scheme, AppLocalizations l10n) {
    final path = raw.trim();
    if (path.isEmpty) {
      toast(l10n.toastDownloadRootEmpty);
      return;
    }
    ref.read(appPrefsProvider.notifier).setDownload(rootDir: path);
    if (!mounted) return;
    toast(l10n.toastDownloadRootUpdated);
  }

  void _saveDownloadTemplate(String raw, ColorScheme scheme, AppLocalizations l10n) {
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

  Widget _buildStorage(ColorScheme scheme, AppLocalizations l10n) {
    final dataDir = resolveDataDir();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle(scheme, l10n.settingsSectionFileLocation),
        _card(
          scheme,
          children: [
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
          ],
        ),
        const SizedBox(height: 8),
        Text(
          l10n.settingsStorageNote,
          style: TextStyle(
            fontSize: 12,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
          ),
        ),
      ],
    );
  }

  Widget _buildAbout(ColorScheme scheme, AppLocalizations l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle(scheme, l10n.appName),
        _card(
          scheme,
          children: [
            _SettingTile(
              icon: Icons.music_note_outlined,
              title: l10n.settingsVersion,
              subtitle: _version.isEmpty
                  ? l10n.settingsVersionUnknown
                  : l10n.settingsVersionFormat(_version),
              trailing: const SizedBox.shrink(),
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
          ],
        ),
        const SizedBox(height: 8),
        Text(
          l10n.settingsAboutDesc,
          style: TextStyle(
            fontSize: 12,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
          ),
        ),
        const SizedBox(height: 12),
        _sectionTitle(scheme, l10n.settingsSectionFontCredits),
        _card(
          scheme,
          children: [
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
          ],
        ),
        const SizedBox(height: 12),
        _sectionTitle(scheme, l10n.settingsSectionDeclaration),
        _card(
          scheme,
          children: [
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
          ],
        ),
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
}

class _SettingTile extends StatelessWidget {
  const _SettingTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.trailing,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
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
            child: Icon(icon, size: 18, color: scheme.primary),
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
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
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
    final l10n = widget.l10n;
    final color = _hsv.toColor();
    return AlertDialog(
      title: Text(l10n.settingsPickerTitle),
      content: SizedBox(
        width: 300,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
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
                      color: theme.colorScheme.outline.withValues(alpha: 0.6),
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
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, color),
          child: Text(l10n.settingsApply),
        ),
      ],
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
