// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../settings_dialog.dart';

extension _SettingsDialogView on _SettingsDialogState {
  Widget _buildSettingsDialog(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;
    final window = MediaQuery.sizeOf(context);
    final animated = ref.watch(appPrefsProvider).sidebarNavStyle == 'animated';
    final devMode = ref.watch(appPrefsProvider).developerMode;
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
      clipBehavior: Clip.antiAlias,
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
                              EtaIcons.close,
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

  List<_SearchEntry> _buildSearchIndex(AppLocalizations l10n) {
    return [
      _SearchEntry(
        SettingsCategory.appearance,
        l10n.settingsThemeMode,
        l10n.settingsThemeModeDesc,
        EtaIcons.moonOutline,
      ),
      _SearchEntry(
        SettingsCategory.appearance,
        l10n.settingsThemeSource,
        l10n.settingsSearchThemeSourceSubtitle,
        EtaIcons.palette2Outline,
      ),
      _SearchEntry(
        SettingsCategory.appearance,
        l10n.settingsGlobalTint,
        l10n.settingsSearchGlobalTintSubtitle,
        EtaIcons.tonalityOutline,
      ),
      _SearchEntry(
        SettingsCategory.appearance,
        l10n.settingsAppearanceStyle,
        l10n.settingsSearchBackgroundSubtitle,
        EtaIcons.picOutline,
      ),
      _SearchEntry(
        SettingsCategory.appearance,
        l10n.settingsRouteTransition,
        l10n.settingsSearchRouteTransitionSubtitle,
        EtaIcons.magic2Outline,
      ),
      _SearchEntry(
        SettingsCategory.appearance,
        l10n.settingsSidebarCollapsed,
        l10n.settingsSearchSidebarSubtitle,
        EtaIcons.menu,
      ),
      _SearchEntry(
        SettingsCategory.appearance,
        l10n.settingsFloatingBar,
        l10n.settingsSearchFloatingBarSubtitle,
        EtaIcons.miniplayerOutline,
      ),
      _SearchEntry(
        SettingsCategory.appearance,
        l10n.settingsSectionFont,
        l10n.settingsSearchFontSubtitle,
        EtaIcons.fontOutline,
      ),
      _SearchEntry(
        SettingsCategory.appearance,
        l10n.settingsLanguageTitle,
        l10n.settingsSearchLanguageSubtitle,
        EtaIcons.translateOutline,
      ),
      _SearchEntry(
        SettingsCategory.appearance,
        l10n.settingsCoverRadius,
        l10n.settingsSearchCoverRadiusSubtitle,
        EtaIcons.square,
      ),
      _SearchEntry(
        SettingsCategory.appearance,
        l10n.settingsWeather,
        l10n.settingsSearchWeatherSubtitle,
        EtaIcons.sunOutline,
      ),
      _SearchEntry(
        SettingsCategory.appearance,
        l10n.settingsPassthrough,
        l10n.settingsSearchPassthroughSubtitle,
        EtaIcons.highQualityOutline,
      ),
      _SearchEntry(
        SettingsCategory.playback,
        l10n.settingsSessionMemory,
        l10n.settingsSearchSessionMemorySubtitle,
        EtaIcons.history,
      ),
      _SearchEntry(
        SettingsCategory.playback,
        l10n.settingsAutoPlay,
        l10n.settingsSearchAutoPlaySubtitle,
        EtaIcons.playCircleOutline,
      ),
      _SearchEntry(
        SettingsCategory.playback,
        l10n.settingsSpectrum,
        l10n.settingsSearchSpectrumSubtitle,
        EtaIcons.soundLine,
      ),
      _SearchEntry(
        SettingsCategory.playback,
        l10n.settingsSpectrumBarWidth,
        l10n.settingsSearchSpectrumWidthSubtitle,
        EtaIcons.columnsOutline,
      ),
      _SearchEntry(
        SettingsCategory.playback,
        l10n.settingsTransitionStyle,
        l10n.settingsTransitionStyleDesc,
        EtaIcons.magic2Outline,
      ),
      _SearchEntry(
        SettingsCategory.lyrics,
        l10n.settingsPlayerLyrics,
        l10n.settingsSearchPlayerLyricsSubtitle,
        EtaIcons.fileMusicOutline,
      ),
      _SearchEntry(
        SettingsCategory.lyrics,
        l10n.settingsBarLyrics,
        l10n.settingsBarLyricsOn,
        EtaIcons.bookOutline,
      ),
      _SearchEntry(
        SettingsCategory.lyrics,
        l10n.settingsBarEnhancedLyrics,
        l10n.settingsBarEnhancedLyricsOn,
        EtaIcons.micOutline,
      ),
      _SearchEntry(
        SettingsCategory.lyrics,
        l10n.settingsLyricFontSize,
        l10n.settingsSearchLyricFontSizeSubtitle,
        EtaIcons.fontSize,
      ),
      _SearchEntry(
        SettingsCategory.lyrics,
        l10n.settingsLyricLineHeight,
        l10n.settingsSearchLyricLineHeightSubtitle,
        EtaIcons.lineHeight,
      ),
      _SearchEntry(
        SettingsCategory.lyrics,
        l10n.settingsSearchColorTitle,
        l10n.settingsSearchColorSubtitle,
        EtaIcons.paletteOutline,
      ),
      _SearchEntry(
        SettingsCategory.lyrics,
        l10n.settingsSearchDesktopLyricsTitle,
        l10n.settingsSearchDesktopLyricsSubtitle,
        EtaIcons.monitorOutline,
      ),
      _SearchEntry(
        SettingsCategory.preset,
        l10n.settingsEnergySaving,
        l10n.settingsSearchEnergySavingSubtitle,
        EtaIcons.leafOutline,
      ),
      _SearchEntry(
        SettingsCategory.preset,
        l10n.settingsPerformanceMode,
        l10n.settingsPerformanceModeOn,
        EtaIcons.flashOutline,
      ),
      _SearchEntry(
        SettingsCategory.preset,
        l10n.settingsSearchDjModeTitle,
        l10n.settingsDjModeOn,
        EtaIcons.magic3Outline,
      ),
      _SearchEntry(
        SettingsCategory.preset,
        l10n.settingsUncensor,
        l10n.settingsSearchUncensorSubtitle,
        EtaIcons.magic2Outline,
      ),
      _SearchEntry(
        SettingsCategory.preset,
        l10n.settingsHideVip,
        l10n.settingsSearchHideVipSubtitle,
        EtaIcons.medalOutline,
      ),
      _SearchEntry(
        SettingsCategory.preset,
        l10n.settingsHideQuality,
        l10n.settingsSearchHideQualitySubtitle,
        EtaIcons.highQualityOutline,
      ),
      _SearchEntry(
        SettingsCategory.preset,
        l10n.settingsShowSubtitle,
        l10n.settingsSearchSubtitleSubtitle,
        EtaIcons.subtitleOutline,
      ),
      _SearchEntry(
        SettingsCategory.download,
        l10n.settingsDataDir,
        l10n.settingsSearchDownloadDirSubtitle,
        EtaIcons.folderOutline,
      ),
      _SearchEntry(
        SettingsCategory.download,
        l10n.settingsSearchFilenameTitle,
        l10n.settingsSearchFilenameSubtitle,
        EtaIcons.fontSizeOutline,
      ),
      _SearchEntry(
        SettingsCategory.download,
        l10n.settingsDownloadConcurrent,
        l10n.settingsSearchConcurrentSubtitle,
        EtaIcons.dashboard4Outline,
      ),
      _SearchEntry(
        SettingsCategory.download,
        l10n.settingsDownloadSpeedLimit,
        l10n.settingsSearchSpeedLimitSubtitle,
        EtaIcons.dashboard4Outline,
      ),
      _SearchEntry(
        SettingsCategory.download,
        l10n.settingsDownloadQuality,
        l10n.settingsSearchQualitySubtitle,
        EtaIcons.highQualityOutline,
      ),
      _SearchEntry(
        SettingsCategory.download,
        l10n.settingsDownloadGrouping,
        l10n.settingsSearchGroupingSubtitle,
        EtaIcons.foldersOutline,
      ),
      _SearchEntry(
        SettingsCategory.download,
        l10n.settingsDownloadHistoryLimit,
        l10n.settingsSearchHistoryLimitSubtitle,
        EtaIcons.historyOutline,
      ),
      _SearchEntry(
        SettingsCategory.storage,
        l10n.settingsDataDir,
        l10n.settingsSearchStorageSubtitle,
        EtaIcons.folderOutline,
      ),
      _SearchEntry(
        SettingsCategory.storage,
        l10n.settingsSectionCache,
        l10n.settingsCacheNote,
        EtaIcons.broomOutline,
      ),
      _SearchEntry(
        SettingsCategory.storage,
        l10n.settingsSongCache,
        l10n.settingsSearchSongCacheSubtitle,
        EtaIcons.pinOutline,
      ),
      _SearchEntry(
        SettingsCategory.storage,
        l10n.settingsSecuritySection,
        l10n.settingsSecurityNote,
        EtaIcons.wastebasketOutline,
      ),
      _SearchEntry(
        SettingsCategory.scrape,
        l10n.settingsCatScrape,
        l10n.settingsScrapeSubtitle,
        EtaIcons.magic3,
      ),
      _SearchEntry(
        SettingsCategory.scanner,
        l10n.settingsCatScanner,
        l10n.settingsScannerSubtitle,
        EtaIcons.search3Outline,
      ),
      _SearchEntry(
        SettingsCategory.mediaSource,
        l10n.settingsCatMediaSource,
        l10n.settingsMediaSourceSubtitle,
        EtaIcons.serverOutline,
      ),
      _SearchEntry(
        SettingsCategory.about,
        l10n.settingsVersion,
        l10n.settingsSearchAboutSubtitle,
        EtaIcons.informationOutline,
      ),
      _SearchEntry(
        SettingsCategory.developer,
        l10n.settingsDevFpsMonitor,
        l10n.settingsDevFpsMonitorDesc,
        EtaIcons.heartbeatOutline,
      ),
    ];
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
            onTap: () => _setCategory(cat),
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
        _buildSearchField(scheme, l10n),
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
                SettingsCategory.shortcuts => const ShortcutsSection(),
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
                SettingsCategory.scanner => const ScansSection(),
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
                    if (mounted) _setCategory(SettingsCategory.about);
                  },
                ),
              },
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildSearchField(ColorScheme scheme, AppLocalizations l10n) {
    return TextField(
      controller: _searchCtrl,
      onChanged: _setQuery,
      style: const TextStyle(fontSize: 13),
      decoration: InputDecoration(
        hintText: l10n.settingsSearchHint,
        prefixIcon: const Icon(EtaIcons.search2, size: 18),
        suffixIcon: _query.isEmpty
            ? null
            : IconButton(
                tooltip: l10n.commonClear,
                iconSize: 16,
                visualDensity: VisualDensity.compact,
                icon: const Icon(EtaIcons.close),
                onPressed: _clearQuery,
              ),
        isDense: true,
      ),
    );
  }

  Widget _buildSearchResults(ColorScheme scheme, AppLocalizations l10n) {
    final q = _query.trim().toLowerCase();
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
              EtaIcons.search2None,
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
                _buildSearchResultTile(scheme, e, q),
            ],
        ],
      ),
    );
  }

  bool _searchMatch(_SearchEntry e, String q, AppLocalizations l10n) =>
      e.title.toLowerCase().contains(q) ||
      e.subtitle.toLowerCase().contains(q) ||
      e.category.label(l10n).toLowerCase().contains(q);

  Widget _buildSearchResultTile(ColorScheme scheme, _SearchEntry e, String q) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: scheme.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          hoverColor: scheme.onSurface.withValues(alpha: 0.05),
          onTap: () {
            _setCategory(e.category);
            _clearQuery();
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
                  EtaIcons.rightSmall,
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
