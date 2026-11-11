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
    final navStyle = sidebarNavStyleFor(
      ref.watch(appPrefsProvider).sidebarNavStyle,
    );
    final indicator = navStyle.slidingIndicator && _catIndicatorReady
        ? navStyle.buildContainerIndicator(
            context: context,
            color: scheme.primary,
            left: _catIndicatorLeft,
            top: _catIndicatorTop,
            height: _catIndicatorHeight,
          )
        : null;
    final devMode = ref.watch(appPrefsProvider).developerMode;
    final downloadModule = ref.watch(appPrefsProvider).downloadModuleEnabled;
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
                            // 隐藏侧栏滚动条（保留滚轮 / 拖拽滚动）。
                            ScrollConfiguration(
                              behavior: const _NoScrollbarBehavior(),
                              child: InkClip(
                                child: ListView(
                                  padding: EdgeInsets.zero,
                                  // 每项恒为 40 高 + 上下各 1.5 的 padding。
                                  itemExtent: 43,
                                  children: [
                                    for (final cat in SettingsCategory.values)
                                      if (cat.visible(devMode, downloadModule))
                                        _buildCategoryItem(
                                          scheme,
                                          cat,
                                          l10n,
                                          navStyle,
                                        ),
                                  ],
                                ),
                              ),
                            ),
                            ?indicator,
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
                  // Stack 作为搜索跳转高亮的坐标参照系（_contentHostKey）。
                  child: Stack(
                    key: _contentHostKey,
                    fit: StackFit.expand,
                    children: [
                      _buildContent(scheme, l10n),
                      if (_flashRect != null)
                        Positioned.fromRect(
                          rect: _flashRect!,
                          child: IgnorePointer(
                            child: SettingsRowFlash(
                              animation: _flashCtrl,
                              color: scheme.primary,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 人工维护的「精选」索引：带图标与更贴切的说明文案。
  ///
  /// 条目只是增益，不是唯一来源——[_autoSearchIndex] 会按设置页实际
  /// 渲染的标题补齐其余设置项（见 [_buildSearchIndex]）。
  List<_SearchEntry> _curatedSearchIndex(AppLocalizations l10n) {
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
        l10n.settingsSidebarCustomize,
        l10n.settingsSidebarCustomizeDesc,
        EtaIcons.listCheck2,
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
        SettingsCategory.playback,
        l10n.settingsCoverLayout,
        l10n.settingsCoverLayoutDesc,
        EtaIcons.square,
      ),
      _SearchEntry(
        SettingsCategory.playback,
        l10n.settingsShowProgressLyric,
        l10n.settingsShowProgressLyricDesc,
        EtaIcons.fileMusicOutline,
      ),
      _SearchEntry(
        SettingsCategory.playback,
        l10n.settingsTimeFormat,
        l10n.settingsTimeFormatDesc,
        EtaIcons.stopwatchOutline,
      ),
      _SearchEntry(
        SettingsCategory.playback,
        l10n.settingsShowPlaybackSource,
        l10n.settingsShowPlaybackSourceDesc,
        EtaIcons.serverOutline,
      ),
      _SearchEntry(
        SettingsCategory.playback,
        l10n.settingsRegisterProtocol,
        l10n.settingsRegisterProtocolDesc,
        EtaIcons.link,
      ),
      _SearchEntry(
        SettingsCategory.audioEffects,
        l10n.settingsSectionEqualizer,
        l10n.settingsAudioEffectsSubtitle,
        EtaIcons.soundLine,
      ),
      _SearchEntry(
        SettingsCategory.audioEffects,
        l10n.settingsNormalization,
        l10n.settingsNormalizationDesc,
        EtaIcons.transferHorizontal,
      ),
      _SearchEntry(
        SettingsCategory.audioEffects,
        l10n.settingsPlaybackSpeed,
        l10n.settingsPlaybackSpeedDesc,
        EtaIcons.stopwatchOutline,
      ),
      _SearchEntry(
        SettingsCategory.audioEffects,
        l10n.settingsPitch,
        l10n.settingsPitchDesc,
        EtaIcons.music2Outline,
      ),
      _SearchEntry(
        SettingsCategory.audioEffects,
        l10n.settingsChannelMerge,
        l10n.settingsChannelMergeDesc,
        EtaIcons.speakerOutline,
      ),
      _SearchEntry(
        SettingsCategory.audioEffects,
        l10n.settingsChorusEnabled,
        l10n.settingsChorusEnabledDesc,
        EtaIcons.music2Outline,
      ),
      _SearchEntry(
        SettingsCategory.audioEffects,
        l10n.settingsPeq,
        l10n.settingsSectionPeqDesc,
        EtaIcons.chartLine,
      ),
      _SearchEntry(
        SettingsCategory.audioEffects,
        l10n.settingsLowfreq,
        l10n.settingsSectionLowfreqDesc,
        EtaIcons.dashboard3,
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
        l10n.settingsSearchColorTitle,
        l10n.settingsSearchColorSubtitle,
        EtaIcons.paletteOutline,
        anchor: l10n.settingsLyricPlayedColor,
      ),
      _SearchEntry(
        SettingsCategory.lyrics,
        l10n.settingsLyricSourceOrder,
        l10n.settingsLyricSourceOrderDesc,
        EtaIcons.serverOutline,
      ),
      _SearchEntry(
        SettingsCategory.lyrics,
        l10n.settingsLyricFormatOrder,
        l10n.settingsLyricFormatOrderDesc,
        EtaIcons.fileMusicOutline,
      ),
      _SearchEntry(
        SettingsCategory.lyrics,
        l10n.settingsSectionLyricExclude,
        l10n.settingsLyricExcludeRulesDesc,
        EtaIcons.magic2Outline,
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
        anchor: l10n.settingsDjMode,
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
        SettingsCategory.render,
        l10n.settingsRippleShader,
        l10n.settingsRippleShaderDesc,
        EtaIcons.dashboard4Outline,
      ),
      _SearchEntry(
        SettingsCategory.render,
        l10n.settingsRippleLowRes,
        l10n.settingsRippleLowResDesc,
        EtaIcons.magic2Outline,
      ),
      _SearchEntry(
        SettingsCategory.render,
        l10n.settingsRippleDamageClip,
        l10n.settingsRippleDamageClipDesc,
        EtaIcons.flashOutline,
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
        anchor: l10n.settingsSectionFilename,
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
        SettingsCategory.scanner,
        l10n.settingsScanAnalyzeLoudness,
        l10n.settingsScanAnalyzeLoudnessOff,
        EtaIcons.soundLine,
      ),
      _SearchEntry(
        SettingsCategory.searchIndex,
        l10n.settingsSearchIndexEnable,
        l10n.settingsSearchIndexEnableOff,
        EtaIcons.search2,
      ),
      _SearchEntry(
        SettingsCategory.searchIndex,
        l10n.settingsSearchIndexLrc,
        l10n.settingsSearchIndexLrcDesc,
        EtaIcons.fileMusicOutline,
      ),
      _SearchEntry(
        SettingsCategory.mediaSource,
        l10n.settingsCatMediaSource,
        l10n.settingsMediaSourceSubtitle,
        EtaIcons.serverOutline,
      ),
      _SearchEntry(
        SettingsCategory.mediaSource,
        l10n.settingsDefaultSource,
        l10n.settingsDefaultSourceDesc,
        EtaIcons.serverOutline,
      ),
      _SearchEntry(
        SettingsCategory.experimentalSource,
        l10n.settingsCatExperimentalSource,
        l10n.settingsExperimentalSourceSubtitle,
        EtaIcons.flaskOutline,
      ),
      _SearchEntry(
        SettingsCategory.experimentalSource,
        l10n.settingsNekoEnable,
        l10n.settingsNekoEnableDesc,
        EtaIcons.flaskOutline,
      ),
      _SearchEntry(
        SettingsCategory.experimentalSource,
        l10n.settingsNekoTitle,
        l10n.settingsNekoNote,
        EtaIcons.flaskOutline,
      ),
      _SearchEntry(
        SettingsCategory.mcp,
        l10n.settingsMcpTitle,
        l10n.settingsMcpSubtitle,
        EtaIcons.chipOutline,
      ),
      _SearchEntry(
        SettingsCategory.about,
        l10n.settingsVersion,
        l10n.settingsSearchAboutSubtitle,
        EtaIcons.informationOutline,
      ),
      _SearchEntry(
        SettingsCategory.about,
        l10n.settingsSectionDeclaration,
        l10n.settingsDeclarationEntryDesc,
        EtaIcons.bookOutline,
        anchor: l10n.settingsSectionLegal,
      ),
      _SearchEntry(
        SettingsCategory.about,
        l10n.settingsSectionPrivacy,
        l10n.settingsPrivacyEntryDesc,
        EtaIcons.shieldOutline,
        anchor: l10n.settingsSectionLegal,
      ),
      _SearchEntry(
        SettingsCategory.about,
        l10n.settingsSectionFontCredits,
        l10n.settingsFontCreditsEntryDesc,
        EtaIcons.fontOutline,
        anchor: l10n.settingsSectionLegal,
      ),
      _SearchEntry(
        SettingsCategory.about,
        l10n.settingsSectionThirdPartyLicenses,
        l10n.settingsThirdPartyLicensesEntryDesc,
        EtaIcons.docmentOutline,
        anchor: l10n.settingsSectionLegal,
      ),
      _SearchEntry(
        SettingsCategory.developer,
        l10n.settingsDevFpsMonitor,
        l10n.settingsDevFpsMonitorDesc,
        EtaIcons.heartbeatOutline,
      ),
    ];
  }

  /// 自动索引：设置页里**实际渲染**的标题（SettingTile / SettingSwitchTile /
  /// SettingSliderTile / SettingSectionTitle / SettingSection）。
  ///
  /// 由设置源码扫描 `title:` / `subtitle:` 生成，覆盖全部设置项；副标题用于
  /// 按描述搜索（取不到时为空白，结果行会省略第二行）。
  ///
  /// 新增设置项时建议同步补一行（顺序与页面一致，便于人工核对）；漏补不会
  /// 造成「搜到跳不过」——[_buildSearchIndex] 只用本表里存在的标题做定位，
  /// 不存在的条目会被丢弃。
  List<_SearchEntry> _autoSearchIndex(AppLocalizations l10n) => [
    _SearchEntry(
      SettingsCategory.storage,
      l10n.settingsSongCache,
      '',
      SettingsCategory.storage.icon,
    ),
    _SearchEntry(
      SettingsCategory.storage,
      l10n.settingsSongCacheLimitTitle,
      '',
      SettingsCategory.storage.icon,
    ),
    _SearchEntry(
      SettingsCategory.storage,
      l10n.settingsSectionCache,
      '',
      SettingsCategory.storage.icon,
    ),
    _SearchEntry(
      SettingsCategory.storage,
      l10n.settingsCacheGroupDisk,
      '',
      SettingsCategory.storage.icon,
    ),
    _SearchEntry(
      SettingsCategory.storage,
      l10n.settingsCacheGroupMem,
      '',
      SettingsCategory.storage.icon,
    ),
    _SearchEntry(
      SettingsCategory.storage,
      l10n.settingsCacheLimitLyric,
      '',
      SettingsCategory.storage.icon,
    ),
    _SearchEntry(
      SettingsCategory.storage,
      l10n.settingsCacheLimitCover,
      '',
      SettingsCategory.storage.icon,
    ),
    _SearchEntry(
      SettingsCategory.storage,
      l10n.settingsLogToFile,
      '',
      SettingsCategory.storage.icon,
    ),
    _SearchEntry(
      SettingsCategory.storage,
      l10n.settingsHistorySection,
      '',
      SettingsCategory.storage.icon,
    ),
    _SearchEntry(
      SettingsCategory.storage,
      l10n.settingsHistoryEnabled,
      '',
      SettingsCategory.storage.icon,
    ),
    _SearchEntry(
      SettingsCategory.storage,
      l10n.settingsHistoryLimit,
      '',
      SettingsCategory.storage.icon,
    ),
    _SearchEntry(
      SettingsCategory.storage,
      l10n.settingsHistoryStats,
      '',
      SettingsCategory.storage.icon,
    ),
    _SearchEntry(
      SettingsCategory.scanner,
      l10n.settingsSectionScanRun,
      '',
      SettingsCategory.scanner.icon,
    ),
    _SearchEntry(
      SettingsCategory.scanner,
      l10n.settingsScanParallelism,
      '',
      SettingsCategory.scanner.icon,
    ),
    _SearchEntry(
      SettingsCategory.scanner,
      l10n.settingsScanBatch,
      '',
      SettingsCategory.scanner.icon,
    ),
    _SearchEntry(
      SettingsCategory.scanner,
      l10n.settingsScanAnalyzeLoudness,
      '',
      SettingsCategory.scanner.icon,
    ),
    _SearchEntry(
      SettingsCategory.scanner,
      l10n.settingsSectionScanLimits,
      '',
      SettingsCategory.scanner.icon,
    ),
    _SearchEntry(
      SettingsCategory.scanner,
      l10n.settingsSectionScanExts,
      '',
      SettingsCategory.scanner.icon,
    ),
    _SearchEntry(
      SettingsCategory.scanner,
      l10n.settingsSectionScanQuarantine,
      '',
      SettingsCategory.scanner.icon,
    ),
    _SearchEntry(
      SettingsCategory.scanner,
      l10n.settingsScanNumberDesc,
      l10n.settingsScanNumberDesc,
      SettingsCategory.scanner.icon,
    ),
    _SearchEntry(
      SettingsCategory.searchIndex,
      l10n.settingsSectionSearchIndex,
      '',
      SettingsCategory.searchIndex.icon,
    ),
    _SearchEntry(
      SettingsCategory.searchIndex,
      l10n.settingsSearchIndexEnable,
      '',
      SettingsCategory.searchIndex.icon,
    ),
    _SearchEntry(
      SettingsCategory.searchIndex,
      l10n.settingsSearchIndexLrc,
      l10n.settingsSearchIndexLrcDesc,
      SettingsCategory.searchIndex.icon,
    ),
    _SearchEntry(
      SettingsCategory.searchIndex,
      l10n.settingsSectionSearchIndexStatus,
      '',
      SettingsCategory.searchIndex.icon,
    ),
    _SearchEntry(
      SettingsCategory.searchIndex,
      l10n.settingsSearchIndexStatusBuilding,
      '',
      SettingsCategory.searchIndex.icon,
    ),
    _SearchEntry(
      SettingsCategory.about,
      l10n.appName,
      '',
      SettingsCategory.about.icon,
    ),
    _SearchEntry(
      SettingsCategory.about,
      l10n.settingsVersion,
      '',
      SettingsCategory.about.icon,
    ),
    _SearchEntry(
      SettingsCategory.about,
      l10n.settingsAudioEngine,
      l10n.settingsAudioEngineDesc,
      SettingsCategory.about.icon,
    ),
    _SearchEntry(
      SettingsCategory.about,
      l10n.settingsSubsonicServer,
      l10n.settingsSubsonicDesc,
      SettingsCategory.about.icon,
    ),
    _SearchEntry(
      SettingsCategory.about,
      l10n.settingsSectionEnvInfo,
      '',
      SettingsCategory.about.icon,
    ),
    _SearchEntry(
      SettingsCategory.about,
      l10n.settingsSectionCommunity,
      '',
      SettingsCategory.about.icon,
    ),
    _SearchEntry(
      SettingsCategory.about,
      l10n.settingsCommunityRepo,
      '',
      SettingsCategory.about.icon,
    ),
    _SearchEntry(
      SettingsCategory.about,
      l10n.settingsSectionThirdPartyService,
      '',
      SettingsCategory.about.icon,
    ),
    _SearchEntry(
      SettingsCategory.about,
      l10n.settingsNekoApiDocs,
      '',
      SettingsCategory.about.icon,
    ),
    _SearchEntry(
      SettingsCategory.about,
      l10n.settingsSectionThanks,
      '',
      SettingsCategory.about.icon,
    ),
    _SearchEntry(
      SettingsCategory.about,
      l10n.settingsSectionLegal,
      '',
      SettingsCategory.about.icon,
    ),
    _SearchEntry(
      SettingsCategory.appearance,
      l10n.settingsSectionTheme,
      l10n.settingsThemeModeDesc,
      SettingsCategory.appearance.icon,
    ),
    _SearchEntry(
      SettingsCategory.appearance,
      l10n.settingsThemeMode,
      l10n.settingsThemeModeDesc,
      SettingsCategory.appearance.icon,
    ),
    _SearchEntry(
      SettingsCategory.appearance,
      l10n.settingsSectionAccent,
      l10n.settingsThemeSourceDesc,
      SettingsCategory.appearance.icon,
    ),
    _SearchEntry(
      SettingsCategory.appearance,
      l10n.settingsThemeSource,
      l10n.settingsThemeSourceDesc,
      SettingsCategory.appearance.icon,
    ),
    _SearchEntry(
      SettingsCategory.appearance,
      l10n.settingsAccentTitle,
      l10n.settingsThemeSourceCustomHint,
      SettingsCategory.appearance.icon,
    ),
    _SearchEntry(
      SettingsCategory.appearance,
      l10n.settingsGlobalTint,
      l10n.settingsGlobalTintDesc,
      SettingsCategory.appearance.icon,
    ),
    _SearchEntry(
      SettingsCategory.appearance,
      l10n.settingsSectionStyle,
      l10n.settingsAppearanceStyleDesc,
      SettingsCategory.appearance.icon,
    ),
    _SearchEntry(
      SettingsCategory.appearance,
      l10n.settingsAppearanceStyle,
      l10n.settingsAppearanceStyleDesc,
      SettingsCategory.appearance.icon,
    ),
    _SearchEntry(
      SettingsCategory.appearance,
      l10n.settingsBackgroundBlur,
      '',
      SettingsCategory.appearance.icon,
    ),
    _SearchEntry(
      SettingsCategory.appearance,
      l10n.settingsBackgroundDim,
      '',
      SettingsCategory.appearance.icon,
    ),
    _SearchEntry(
      SettingsCategory.appearance,
      l10n.settingsBackgroundScale,
      '',
      SettingsCategory.appearance.icon,
    ),
    _SearchEntry(
      SettingsCategory.appearance,
      l10n.settingsSectionLayout,
      '',
      SettingsCategory.appearance.icon,
    ),
    _SearchEntry(
      SettingsCategory.appearance,
      l10n.settingsFloatingBar,
      '',
      SettingsCategory.appearance.icon,
    ),
    _SearchEntry(
      SettingsCategory.appearance,
      l10n.settingsSidebarCollapsed,
      l10n.settingsSidebarCollapsedDesc,
      SettingsCategory.appearance.icon,
    ),
    _SearchEntry(
      SettingsCategory.appearance,
      l10n.settingsSidebarNavStyle,
      l10n.settingsSidebarNavStyleDesc,
      SettingsCategory.appearance.icon,
    ),
    _SearchEntry(
      SettingsCategory.appearance,
      l10n.settingsSidebarCustomize,
      l10n.settingsSidebarCustomizeDesc,
      SettingsCategory.appearance.icon,
    ),
    _SearchEntry(
      SettingsCategory.appearance,
      l10n.settingsRouteTransition,
      l10n.settingsRouteTransitionDesc,
      SettingsCategory.appearance.icon,
    ),
    _SearchEntry(
      SettingsCategory.appearance,
      l10n.settingsSectionFont,
      l10n.settingsFontMiSans,
      SettingsCategory.appearance.icon,
    ),
    _SearchEntry(
      SettingsCategory.appearance,
      l10n.settingsFontTitle,
      l10n.settingsFontMiSans,
      SettingsCategory.appearance.icon,
    ),
    _SearchEntry(
      SettingsCategory.appearance,
      l10n.settingsSectionLanguage,
      l10n.settingsLanguageDesc,
      SettingsCategory.appearance.icon,
    ),
    _SearchEntry(
      SettingsCategory.appearance,
      l10n.settingsLanguageTitle,
      l10n.settingsLanguageDesc,
      SettingsCategory.appearance.icon,
    ),
    _SearchEntry(
      SettingsCategory.appearance,
      l10n.settingsSectionCover,
      '',
      SettingsCategory.appearance.icon,
    ),
    _SearchEntry(
      SettingsCategory.appearance,
      l10n.settingsCoverRadius,
      '',
      SettingsCategory.appearance.icon,
    ),
    _SearchEntry(
      SettingsCategory.appearance,
      l10n.settingsSectionWeather,
      l10n.settingsWeatherDesc,
      SettingsCategory.appearance.icon,
    ),
    _SearchEntry(
      SettingsCategory.appearance,
      l10n.settingsWeather,
      l10n.settingsWeatherDesc,
      SettingsCategory.appearance.icon,
    ),
    _SearchEntry(
      SettingsCategory.appearance,
      l10n.settingsWeatherAutoLocate,
      l10n.settingsWeatherAutoLocateDesc,
      SettingsCategory.appearance.icon,
    ),
    _SearchEntry(
      SettingsCategory.appearance,
      l10n.settingsWeatherLocateSource,
      l10n.settingsWeatherLocateSourceDesc,
      SettingsCategory.appearance.icon,
    ),
    _SearchEntry(
      SettingsCategory.audioEffects,
      l10n.settingsSectionEqualizer,
      '',
      SettingsCategory.audioEffects.icon,
    ),
    _SearchEntry(
      SettingsCategory.audioEffects,
      l10n.settingsEqEnabled,
      '',
      SettingsCategory.audioEffects.icon,
    ),
    _SearchEntry(
      SettingsCategory.audioEffects,
      l10n.settingsEqPreset,
      '',
      SettingsCategory.audioEffects.icon,
    ),
    _SearchEntry(
      SettingsCategory.audioEffects,
      l10n.settingsEqLimiter,
      l10n.settingsEqLimiterDesc,
      SettingsCategory.audioEffects.icon,
    ),
    _SearchEntry(
      SettingsCategory.audioEffects,
      l10n.settingsEqReset,
      '',
      SettingsCategory.audioEffects.icon,
    ),
    _SearchEntry(
      SettingsCategory.audioEffects,
      l10n.settingsSectionPeq,
      '',
      SettingsCategory.audioEffects.icon,
    ),
    _SearchEntry(
      SettingsCategory.audioEffects,
      l10n.settingsPeq,
      '',
      SettingsCategory.audioEffects.icon,
    ),
    _SearchEntry(
      SettingsCategory.audioEffects,
      l10n.settingsPeqAddBand,
      '',
      SettingsCategory.audioEffects.icon,
    ),
    _SearchEntry(
      SettingsCategory.audioEffects,
      l10n.settingsSectionLowfreq,
      '',
      SettingsCategory.audioEffects.icon,
    ),
    _SearchEntry(
      SettingsCategory.audioEffects,
      l10n.settingsLowfreq,
      '',
      SettingsCategory.audioEffects.icon,
    ),
    _SearchEntry(
      SettingsCategory.audioEffects,
      l10n.settingsLowfreqHpfCutoff,
      '',
      SettingsCategory.audioEffects.icon,
    ),
    _SearchEntry(
      SettingsCategory.audioEffects,
      l10n.settingsSectionChannels,
      '',
      SettingsCategory.audioEffects.icon,
    ),
    _SearchEntry(
      SettingsCategory.audioEffects,
      l10n.settingsChannelMerge,
      '',
      SettingsCategory.audioEffects.icon,
    ),
    _SearchEntry(
      SettingsCategory.audioEffects,
      l10n.settingsSectionChorus,
      '',
      SettingsCategory.audioEffects.icon,
    ),
    _SearchEntry(
      SettingsCategory.audioEffects,
      l10n.settingsChorusEnabled,
      '',
      SettingsCategory.audioEffects.icon,
    ),
    _SearchEntry(
      SettingsCategory.audioEffects,
      l10n.settingsSectionNormalization,
      '',
      SettingsCategory.audioEffects.icon,
    ),
    _SearchEntry(
      SettingsCategory.audioEffects,
      l10n.settingsNormalization,
      '',
      SettingsCategory.audioEffects.icon,
    ),
    _SearchEntry(
      SettingsCategory.audioEffects,
      l10n.settingsNormalizationMode,
      l10n.settingsNormalizationModeDesc,
      SettingsCategory.audioEffects.icon,
    ),
    _SearchEntry(
      SettingsCategory.audioEffects,
      l10n.settingsSectionSpeed,
      '',
      SettingsCategory.audioEffects.icon,
    ),
    _SearchEntry(
      SettingsCategory.audioEffects,
      l10n.settingsPlaybackSpeedNormal,
      l10n.settingsPlaybackSpeedDesc,
      SettingsCategory.audioEffects.icon,
    ),
    _SearchEntry(
      SettingsCategory.audioEffects,
      l10n.settingsSectionPitch,
      '',
      SettingsCategory.audioEffects.icon,
    ),
    _SearchEntry(
      SettingsCategory.audioEffects,
      l10n.settingsPitchNormal,
      l10n.settingsPitchDesc,
      SettingsCategory.audioEffects.icon,
    ),
    _SearchEntry(
      SettingsCategory.developer,
      l10n.settingsDeveloperTitle,
      '',
      SettingsCategory.developer.icon,
    ),
    _SearchEntry(
      SettingsCategory.developer,
      l10n.settingsDeveloperMode,
      '',
      SettingsCategory.developer.icon,
    ),
    _SearchEntry(
      SettingsCategory.developer,
      l10n.settingsDevFpsMonitor,
      l10n.settingsDevFpsMonitorDesc,
      SettingsCategory.developer.icon,
    ),
    _SearchEntry(
      SettingsCategory.developer,
      l10n.settingsDeveloperDownloadModule,
      l10n.settingsDeveloperDownloadModuleDesc,
      SettingsCategory.developer.icon,
    ),
    _SearchEntry(
      SettingsCategory.download,
      l10n.settingsSectionDir,
      '',
      SettingsCategory.download.icon,
    ),
    _SearchEntry(
      SettingsCategory.download,
      l10n.settingsSectionFilename,
      '',
      SettingsCategory.download.icon,
    ),
    _SearchEntry(
      SettingsCategory.download,
      l10n.settingsSectionQuality,
      '',
      SettingsCategory.download.icon,
    ),
    _SearchEntry(
      SettingsCategory.download,
      l10n.settingsDownloadQuality,
      '',
      SettingsCategory.download.icon,
    ),
    _SearchEntry(
      SettingsCategory.download,
      l10n.settingsSectionConcurrent,
      '',
      SettingsCategory.download.icon,
    ),
    _SearchEntry(
      SettingsCategory.download,
      l10n.settingsDownloadConcurrent,
      '',
      SettingsCategory.download.icon,
    ),
    _SearchEntry(
      SettingsCategory.download,
      l10n.settingsDownloadGrouping,
      '',
      SettingsCategory.download.icon,
    ),
    _SearchEntry(
      SettingsCategory.download,
      l10n.settingsSectionSpeedLimit,
      '',
      SettingsCategory.download.icon,
    ),
    _SearchEntry(
      SettingsCategory.download,
      l10n.settingsDownloadSpeedLimit,
      '',
      SettingsCategory.download.icon,
    ),
    _SearchEntry(
      SettingsCategory.download,
      l10n.settingsSectionHistory,
      '',
      SettingsCategory.download.icon,
    ),
    _SearchEntry(
      SettingsCategory.download,
      l10n.settingsDownloadHistoryLimit,
      '',
      SettingsCategory.download.icon,
    ),
    _SearchEntry(
      SettingsCategory.download,
      l10n.settingsSectionFingerprint,
      l10n.settingsDownloadDynamicFingerprintDesc,
      SettingsCategory.download.icon,
    ),
    _SearchEntry(
      SettingsCategory.download,
      l10n.settingsDownloadDynamicFingerprint,
      l10n.settingsDownloadDynamicFingerprintDesc,
      SettingsCategory.download.icon,
    ),
    _SearchEntry(
      SettingsCategory.download,
      l10n.settingsResetFingerprint,
      l10n.settingsResetFingerprintDesc,
      SettingsCategory.download.icon,
    ),
    _SearchEntry(
      SettingsCategory.experimentalSource,
      l10n.settingsNekoTitle,
      l10n.settingsNekoEnableDesc,
      SettingsCategory.experimentalSource.icon,
    ),
    _SearchEntry(
      SettingsCategory.experimentalSource,
      l10n.settingsNekoEnable,
      l10n.settingsNekoEnableDesc,
      SettingsCategory.experimentalSource.icon,
    ),
    _SearchEntry(
      SettingsCategory.experimentalSource,
      l10n.settingsNekoLogin,
      '',
      SettingsCategory.experimentalSource.icon,
    ),
    _SearchEntry(
      SettingsCategory.lyrics,
      l10n.settingsSectionPlayerLyrics,
      '',
      SettingsCategory.lyrics.icon,
    ),
    _SearchEntry(
      SettingsCategory.lyrics,
      l10n.settingsPlayerLyrics,
      '',
      SettingsCategory.lyrics.icon,
    ),
    _SearchEntry(
      SettingsCategory.lyrics,
      l10n.settingsBarLyrics,
      '',
      SettingsCategory.lyrics.icon,
    ),
    _SearchEntry(
      SettingsCategory.lyrics,
      l10n.settingsBarEnhancedLyrics,
      '',
      SettingsCategory.lyrics.icon,
    ),
    _SearchEntry(
      SettingsCategory.lyrics,
      l10n.settingsShowTranslation,
      '',
      SettingsCategory.lyrics.icon,
    ),
    _SearchEntry(
      SettingsCategory.lyrics,
      l10n.settingsShowRomanization,
      '',
      SettingsCategory.lyrics.icon,
    ),
    _SearchEntry(
      SettingsCategory.lyrics,
      l10n.settingsSectionLyricEngine,
      l10n.settingsLyricEngineDesc,
      SettingsCategory.lyrics.icon,
    ),
    _SearchEntry(
      SettingsCategory.lyrics,
      l10n.settingsLyricEngine,
      l10n.settingsLyricEngineDesc,
      SettingsCategory.lyrics.icon,
    ),
    _SearchEntry(
      SettingsCategory.lyrics,
      l10n.settingsSectionLyricStyle,
      '',
      SettingsCategory.lyrics.icon,
    ),
    _SearchEntry(
      SettingsCategory.lyrics,
      l10n.settingsLyricFontSize,
      '',
      SettingsCategory.lyrics.icon,
    ),
    _SearchEntry(
      SettingsCategory.lyrics,
      l10n.settingsLyricFollowAccent,
      l10n.settingsLyricFollowAccentDesc,
      SettingsCategory.lyrics.icon,
    ),
    _SearchEntry(
      SettingsCategory.lyrics,
      l10n.settingsLyricAdaptiveFontSize,
      '',
      SettingsCategory.lyrics.icon,
    ),
    _SearchEntry(
      SettingsCategory.lyrics,
      l10n.settingsLyricFontWeight,
      l10n.settingsLyricFontWeightDesc,
      SettingsCategory.lyrics.icon,
    ),
    _SearchEntry(
      SettingsCategory.lyrics,
      l10n.settingsLyricPlayedColor,
      l10n.settingsLyricPlayedColorDesc,
      SettingsCategory.lyrics.icon,
    ),
    _SearchEntry(
      SettingsCategory.lyrics,
      l10n.settingsLyricUnplayedColor,
      l10n.settingsLyricUnplayedColorDesc,
      SettingsCategory.lyrics.icon,
    ),
    _SearchEntry(
      SettingsCategory.lyrics,
      l10n.settingsLyricSourceOrder,
      l10n.settingsLyricSourceOrderDesc,
      SettingsCategory.lyrics.icon,
    ),
    _SearchEntry(
      SettingsCategory.lyrics,
      l10n.settingsLyricFormatOrder,
      l10n.settingsLyricFormatOrderDesc,
      SettingsCategory.lyrics.icon,
    ),
    _SearchEntry(
      SettingsCategory.lyrics,
      l10n.settingsLyricTtml,
      l10n.settingsLyricTtmlEnableDesc,
      SettingsCategory.lyrics.icon,
    ),
    _SearchEntry(
      SettingsCategory.lyrics,
      l10n.settingsLyricTtmlEnable,
      l10n.settingsLyricTtmlEnableDesc,
      SettingsCategory.lyrics.icon,
    ),
    _SearchEntry(
      SettingsCategory.lyrics,
      l10n.settingsLyricTtmlServer,
      '',
      SettingsCategory.lyrics.icon,
    ),
    _SearchEntry(
      SettingsCategory.lyrics,
      l10n.settingsSectionLyricExclude,
      '',
      SettingsCategory.lyrics.icon,
    ),
    _SearchEntry(
      SettingsCategory.lyrics,
      l10n.settingsLyricExcludeEnabled,
      '',
      SettingsCategory.lyrics.icon,
    ),
    _SearchEntry(
      SettingsCategory.lyrics,
      l10n.settingsLyricExcludeRules,
      l10n.settingsLyricExcludeRulesDesc,
      SettingsCategory.lyrics.icon,
    ),
    _SearchEntry(
      SettingsCategory.lyrics,
      l10n.settingsSectionLyricWall,
      '',
      SettingsCategory.lyrics.icon,
    ),
    _SearchEntry(
      SettingsCategory.lyrics,
      l10n.settingsAmllAlign,
      '',
      SettingsCategory.lyrics.icon,
    ),
    _SearchEntry(
      SettingsCategory.lyrics,
      l10n.settingsAmllDim,
      '',
      SettingsCategory.lyrics.icon,
    ),
    _SearchEntry(
      SettingsCategory.lyrics,
      l10n.settingsAmllWordSweep,
      '',
      SettingsCategory.lyrics.icon,
    ),
    _SearchEntry(
      SettingsCategory.lyrics,
      l10n.settingsAmllHidePassed,
      '',
      SettingsCategory.lyrics.icon,
    ),
    _SearchEntry(
      SettingsCategory.lyrics,
      l10n.settingsAmllScale,
      l10n.settingsAmllBlurNote,
      SettingsCategory.lyrics.icon,
    ),
    _SearchEntry(
      SettingsCategory.lyrics,
      l10n.settingsAmllBlur,
      l10n.settingsAmllBlurNote,
      SettingsCategory.lyrics.icon,
    ),
    _SearchEntry(
      SettingsCategory.lyrics,
      l10n.settingsAmllSpring,
      '',
      SettingsCategory.lyrics.icon,
    ),
    _SearchEntry(
      SettingsCategory.mcp,
      l10n.settingsMcpTitle,
      '',
      SettingsCategory.mcp.icon,
    ),
    _SearchEntry(
      SettingsCategory.mcp,
      l10n.settingsMcpEnable,
      '',
      SettingsCategory.mcp.icon,
    ),
    _SearchEntry(
      SettingsCategory.mcp,
      l10n.settingsMcpPort,
      l10n.settingsMcpPortDesc,
      SettingsCategory.mcp.icon,
    ),
    _SearchEntry(
      SettingsCategory.mcp,
      l10n.settingsMcpKey,
      '',
      SettingsCategory.mcp.icon,
    ),
    _SearchEntry(
      SettingsCategory.mcp,
      l10n.settingsMcpAllowKeyless,
      l10n.settingsMcpAllowKeylessDesc,
      SettingsCategory.mcp.icon,
    ),
    _SearchEntry(
      SettingsCategory.mcp,
      l10n.settingsMcpAllowLan,
      l10n.settingsMcpAllowLanDesc,
      SettingsCategory.mcp.icon,
    ),
    _SearchEntry(
      SettingsCategory.mcp,
      l10n.settingsMcpShell,
      l10n.settingsMcpShellDesc,
      SettingsCategory.mcp.icon,
    ),
    _SearchEntry(
      SettingsCategory.mcp,
      l10n.settingsMcpShellUsage,
      '',
      SettingsCategory.mcp.icon,
    ),
    _SearchEntry(
      SettingsCategory.mcp,
      l10n.settingsMcpCapsTitle,
      '',
      SettingsCategory.mcp.icon,
    ),
    _SearchEntry(
      SettingsCategory.mcp,
      l10n.settingsMcpEndpointsTitle,
      '',
      SettingsCategory.mcp.icon,
    ),
    _SearchEntry(
      SettingsCategory.mcp,
      l10n.settingsMcpStatusDesc,
      l10n.settingsMcpStatusDesc,
      SettingsCategory.mcp.icon,
    ),
    _SearchEntry(
      SettingsCategory.mcp,
      l10n.settingsMcpLanAddress,
      '',
      SettingsCategory.mcp.icon,
    ),
    _SearchEntry(
      SettingsCategory.mcp,
      l10n.settingsMcpEndpointMcp,
      '',
      SettingsCategory.mcp.icon,
    ),
    _SearchEntry(
      SettingsCategory.mcp,
      l10n.settingsMcpEndpointRest,
      '',
      SettingsCategory.mcp.icon,
    ),
    _SearchEntry(
      SettingsCategory.mcp,
      l10n.settingsMcpEndpointWs,
      '',
      SettingsCategory.mcp.icon,
    ),
    _SearchEntry(
      SettingsCategory.playback,
      l10n.settingsSectionAudio,
      '',
      SettingsCategory.playback.icon,
    ),
    _SearchEntry(
      SettingsCategory.playback,
      l10n.settingsPassthrough,
      '',
      SettingsCategory.playback.icon,
    ),
    _SearchEntry(
      SettingsCategory.playback,
      l10n.settingsOutputDevice,
      '',
      SettingsCategory.playback.icon,
    ),
    _SearchEntry(
      SettingsCategory.playback,
      l10n.settingsEngine,
      '',
      SettingsCategory.playback.icon,
    ),
    _SearchEntry(
      SettingsCategory.playback,
      l10n.settingsMemoryPlaySection,
      '',
      SettingsCategory.playback.icon,
    ),
    _SearchEntry(
      SettingsCategory.playback,
      l10n.settingsMemoryPlayTitle,
      '',
      SettingsCategory.playback.icon,
    ),
    _SearchEntry(
      SettingsCategory.playback,
      l10n.settingsSectionMemory,
      '',
      SettingsCategory.playback.icon,
    ),
    _SearchEntry(
      SettingsCategory.playback,
      l10n.settingsSessionMemory,
      '',
      SettingsCategory.playback.icon,
    ),
    _SearchEntry(
      SettingsCategory.playback,
      l10n.settingsAutoPlay,
      '',
      SettingsCategory.playback.icon,
    ),
    _SearchEntry(
      SettingsCategory.playback,
      l10n.settingsSectionClose,
      '',
      SettingsCategory.playback.icon,
    ),
    _SearchEntry(
      SettingsCategory.playback,
      l10n.settingsCloseBehavior,
      '',
      SettingsCategory.playback.icon,
    ),
    _SearchEntry(
      SettingsCategory.playback,
      l10n.settingsSectionSleepTimer,
      '',
      SettingsCategory.playback.icon,
    ),
    _SearchEntry(
      SettingsCategory.playback,
      l10n.sleepTimerPresets,
      '',
      SettingsCategory.playback.icon,
    ),
    _SearchEntry(
      SettingsCategory.playback,
      l10n.settingsSectionSpectrum,
      '',
      SettingsCategory.playback.icon,
    ),
    _SearchEntry(
      SettingsCategory.playback,
      l10n.settingsSpectrum,
      '',
      SettingsCategory.playback.icon,
    ),
    _SearchEntry(
      SettingsCategory.playback,
      l10n.settingsCoverBeatScale,
      '',
      SettingsCategory.playback.icon,
    ),
    _SearchEntry(
      SettingsCategory.playback,
      l10n.settingsSpectrumBarWidth,
      '',
      SettingsCategory.playback.icon,
    ),
    _SearchEntry(
      SettingsCategory.playback,
      l10n.settingsSpectrumStyle,
      l10n.settingsSpectrumStyleDesc,
      SettingsCategory.playback.icon,
    ),
    _SearchEntry(
      SettingsCategory.playback,
      l10n.settingsReverseSpectrum,
      l10n.settingsReverseSpectrumDesc,
      SettingsCategory.playback.icon,
    ),
    _SearchEntry(
      SettingsCategory.playback,
      l10n.settingsSpectrumAgc,
      '',
      SettingsCategory.playback.icon,
    ),
    _SearchEntry(
      SettingsCategory.playback,
      l10n.settingsSpectrumGamma,
      '',
      SettingsCategory.playback.icon,
    ),
    _SearchEntry(
      SettingsCategory.playback,
      l10n.settingsSpectrumGammaValue,
      '',
      SettingsCategory.playback.icon,
    ),
    _SearchEntry(
      SettingsCategory.playback,
      l10n.settingsSpectrumTilt,
      '',
      SettingsCategory.playback.icon,
    ),
    _SearchEntry(
      SettingsCategory.playback,
      l10n.settingsSpectrumTiltValue,
      '',
      SettingsCategory.playback.icon,
    ),
    _SearchEntry(
      SettingsCategory.playback,
      l10n.settingsSpectrumPeakHold,
      '',
      SettingsCategory.playback.icon,
    ),
    _SearchEntry(
      SettingsCategory.playback,
      l10n.settingsBarSpectrum,
      '',
      SettingsCategory.playback.icon,
    ),
    _SearchEntry(
      SettingsCategory.playback,
      l10n.settingsSectionExperience,
      l10n.settingsAutoImmersiveDesc,
      SettingsCategory.playback.icon,
    ),
    _SearchEntry(
      SettingsCategory.playback,
      l10n.settingsAutoImmersive,
      l10n.settingsAutoImmersiveDesc,
      SettingsCategory.playback.icon,
    ),
    _SearchEntry(
      SettingsCategory.playback,
      l10n.settingsCrossfade,
      l10n.settingsCrossfadeDesc,
      SettingsCategory.playback.icon,
    ),
    _SearchEntry(
      SettingsCategory.playback,
      l10n.settingsCrossfadeDuration,
      '',
      SettingsCategory.playback.icon,
    ),
    _SearchEntry(
      SettingsCategory.playback,
      l10n.settingsSectionSystem,
      l10n.settingsMediaSessionDesc,
      SettingsCategory.playback.icon,
    ),
    _SearchEntry(
      SettingsCategory.playback,
      l10n.settingsMediaSession,
      l10n.settingsMediaSessionDesc,
      SettingsCategory.playback.icon,
    ),
    _SearchEntry(
      SettingsCategory.playback,
      l10n.settingsTransitionStyle,
      l10n.settingsTransitionStyleDesc,
      SettingsCategory.playback.icon,
    ),
    _SearchEntry(
      SettingsCategory.playback,
      l10n.settingsPlayerBackground,
      l10n.settingsPlayerBackgroundDesc,
      SettingsCategory.playback.icon,
    ),
    _SearchEntry(
      SettingsCategory.playback,
      l10n.settingsPlayerBgRippleSpeed,
      '',
      SettingsCategory.playback.icon,
    ),
    _SearchEntry(
      SettingsCategory.playback,
      l10n.settingsAdaptiveRenderQuality,
      '',
      SettingsCategory.playback.icon,
    ),
    _SearchEntry(
      SettingsCategory.playback,
      l10n.settingsPlayerBgFlowSpeed,
      '',
      SettingsCategory.playback.icon,
    ),
    _SearchEntry(
      SettingsCategory.playback,
      l10n.settingsPlayerBgRenderScale,
      '',
      SettingsCategory.playback.icon,
    ),
    _SearchEntry(
      SettingsCategory.playback,
      l10n.settingsPlayerBgFps,
      '',
      SettingsCategory.playback.icon,
    ),
    _SearchEntry(
      SettingsCategory.playback,
      l10n.settingsPlayerBgFreezeOnPause,
      '',
      SettingsCategory.playback.icon,
    ),
    _SearchEntry(
      SettingsCategory.playback,
      l10n.settingsPlayerBgBeat,
      '',
      SettingsCategory.playback.icon,
    ),
    _SearchEntry(
      SettingsCategory.playback,
      l10n.settingsCoverLayout,
      l10n.settingsCoverLayoutDesc,
      SettingsCategory.playback.icon,
    ),
    _SearchEntry(
      SettingsCategory.playback,
      l10n.settingsCoverLyricRatio,
      l10n.settingsCoverLyricRatioDesc,
      SettingsCategory.playback.icon,
    ),
    _SearchEntry(
      SettingsCategory.playback,
      l10n.settingsAutoCenterCover,
      l10n.settingsAutoCenterCoverDesc,
      SettingsCategory.playback.icon,
    ),
    _SearchEntry(
      SettingsCategory.playback,
      l10n.settingsFollowCoverColor,
      l10n.settingsFollowCoverColorDesc,
      SettingsCategory.playback.icon,
    ),
    _SearchEntry(
      SettingsCategory.playback,
      l10n.settingsShowProgressTooltip,
      l10n.settingsShowProgressTooltipDesc,
      SettingsCategory.playback.icon,
    ),
    _SearchEntry(
      SettingsCategory.playback,
      l10n.settingsShowProgressLyric,
      l10n.settingsShowProgressLyricDesc,
      SettingsCategory.playback.icon,
    ),
    _SearchEntry(
      SettingsCategory.playback,
      l10n.settingsSnapToLyric,
      l10n.settingsSnapToLyricDesc,
      SettingsCategory.playback.icon,
    ),
    _SearchEntry(
      SettingsCategory.playback,
      l10n.settingsTimeFormat,
      l10n.settingsTimeFormatDesc,
      SettingsCategory.playback.icon,
    ),
    _SearchEntry(
      SettingsCategory.playback,
      l10n.settingsShowPlaybackSource,
      l10n.settingsShowPlaybackSourceDesc,
      SettingsCategory.playback.icon,
    ),
    _SearchEntry(
      SettingsCategory.playback,
      l10n.settingsRegisterProtocol,
      '',
      SettingsCategory.playback.icon,
    ),
    _SearchEntry(
      SettingsCategory.preset,
      l10n.settingsEnergySaving,
      '',
      SettingsCategory.preset.icon,
    ),
    _SearchEntry(
      SettingsCategory.preset,
      l10n.settingsPerformanceMode,
      '',
      SettingsCategory.preset.icon,
    ),
    _SearchEntry(
      SettingsCategory.preset,
      l10n.settingsSectionFilter,
      '',
      SettingsCategory.preset.icon,
    ),
    _SearchEntry(
      SettingsCategory.preset,
      l10n.settingsDjMode,
      '',
      SettingsCategory.preset.icon,
    ),
    _SearchEntry(
      SettingsCategory.preset,
      l10n.settingsDjEnhanced,
      l10n.settingsDjEnhancedDesc,
      SettingsCategory.preset.icon,
    ),
    _SearchEntry(
      SettingsCategory.preset,
      l10n.settingsDjCustom,
      l10n.settingsDjCustomHint,
      SettingsCategory.preset.icon,
    ),
    _SearchEntry(
      SettingsCategory.preset,
      l10n.settingsSectionLyricsFilter,
      '',
      SettingsCategory.preset.icon,
    ),
    _SearchEntry(
      SettingsCategory.preset,
      l10n.settingsUncensor,
      '',
      SettingsCategory.preset.icon,
    ),
    _SearchEntry(
      SettingsCategory.preset,
      l10n.settingsSectionListDisplay,
      '',
      SettingsCategory.preset.icon,
    ),
    _SearchEntry(
      SettingsCategory.preset,
      l10n.settingsHideVip,
      '',
      SettingsCategory.preset.icon,
    ),
    _SearchEntry(
      SettingsCategory.preset,
      l10n.settingsHideQuality,
      '',
      SettingsCategory.preset.icon,
    ),
    _SearchEntry(
      SettingsCategory.preset,
      l10n.settingsShowSubtitle,
      '',
      SettingsCategory.preset.icon,
    ),
    _SearchEntry(
      SettingsCategory.preset,
      l10n.settingsWeirdEffects,
      '',
      SettingsCategory.preset.icon,
    ),
    _SearchEntry(
      SettingsCategory.render,
      l10n.settingsCatRender,
      '',
      SettingsCategory.render.icon,
    ),
    _SearchEntry(
      SettingsCategory.render,
      l10n.settingsRenderFps,
      '',
      SettingsCategory.render.icon,
    ),
    _SearchEntry(
      SettingsCategory.render,
      l10n.settingsRippleShader,
      l10n.settingsRippleShaderDesc,
      SettingsCategory.render.icon,
    ),
    _SearchEntry(
      SettingsCategory.render,
      l10n.settingsRippleLowRes,
      l10n.settingsRippleLowResDesc,
      SettingsCategory.render.icon,
    ),
    _SearchEntry(
      SettingsCategory.render,
      l10n.settingsRippleDamageClip,
      l10n.settingsRippleDamageClipDesc,
      SettingsCategory.render.icon,
    ),
    _SearchEntry(
      SettingsCategory.render,
      l10n.settingsLyricsEdgeFade,
      l10n.settingsLyricsEdgeFadeDesc,
      SettingsCategory.render.icon,
    ),
    _SearchEntry(
      SettingsCategory.render,
      l10n.settingsSectionPower,
      '',
      SettingsCategory.render.icon,
    ),
    _SearchEntry(
      SettingsCategory.render,
      l10n.settingsPowerSaver,
      '',
      SettingsCategory.render.icon,
    ),
    _SearchEntry(
      SettingsCategory.render,
      l10n.settingsSuppressSleep,
      '',
      SettingsCategory.render.icon,
    ),
    _SearchEntry(
      SettingsCategory.scrape,
      l10n.settingsSectionScrapeDirs,
      '',
      SettingsCategory.scrape.icon,
    ),
    _SearchEntry(
      SettingsCategory.scrape,
      l10n.settingsSectionScrapeSources,
      l10n.settingsScrapeSourceDesc,
      SettingsCategory.scrape.icon,
    ),
    _SearchEntry(
      SettingsCategory.scrape,
      l10n.settingsScrapeSourceMusicBrainz,
      l10n.settingsScrapeSourceDesc,
      SettingsCategory.scrape.icon,
    ),
    _SearchEntry(
      SettingsCategory.scrape,
      l10n.settingsScrapeSourceDeezer,
      l10n.settingsScrapeSourceDesc,
      SettingsCategory.scrape.icon,
    ),
    _SearchEntry(
      SettingsCategory.scrape,
      l10n.settingsScrapeSourceItunes,
      l10n.settingsScrapeSourceDesc,
      SettingsCategory.scrape.icon,
    ),
    _SearchEntry(
      SettingsCategory.scrape,
      l10n.settingsScrapeSourceNetease,
      l10n.settingsScrapeSourceDesc,
      SettingsCategory.scrape.icon,
    ),
    _SearchEntry(
      SettingsCategory.scrape,
      l10n.settingsScrapeSourceQQMusic,
      l10n.settingsScrapeSourceDesc,
      SettingsCategory.scrape.icon,
    ),
    _SearchEntry(
      SettingsCategory.scrape,
      l10n.settingsScrapeSourceKugou,
      l10n.settingsScrapeSourceDesc,
      SettingsCategory.scrape.icon,
    ),
    _SearchEntry(
      SettingsCategory.scrape,
      l10n.settingsScrapeSourceKuwo,
      l10n.settingsScrapeSourceDesc,
      SettingsCategory.scrape.icon,
    ),
    _SearchEntry(
      SettingsCategory.scrape,
      l10n.settingsScrapeSourceMigu,
      l10n.settingsScrapeSourceDesc,
      SettingsCategory.scrape.icon,
    ),
    _SearchEntry(
      SettingsCategory.scrape,
      l10n.settingsScrapeSourceAcoustID,
      l10n.settingsScrapeSourceDesc,
      SettingsCategory.scrape.icon,
    ),
    _SearchEntry(
      SettingsCategory.scrape,
      l10n.settingsSectionScrapeWrite,
      l10n.settingsScrapeWriteDesc,
      SettingsCategory.scrape.icon,
    ),
    _SearchEntry(
      SettingsCategory.scrape,
      l10n.settingsScrapeEmbedMetadata,
      l10n.settingsScrapeWriteDesc,
      SettingsCategory.scrape.icon,
    ),
    _SearchEntry(
      SettingsCategory.scrape,
      l10n.settingsScrapeEmbedCover,
      l10n.settingsScrapeWriteDesc,
      SettingsCategory.scrape.icon,
    ),
    _SearchEntry(
      SettingsCategory.scrape,
      l10n.settingsScrapeEmbedLyrics,
      l10n.settingsScrapeWriteDesc,
      SettingsCategory.scrape.icon,
    ),
    _SearchEntry(
      SettingsCategory.scrape,
      l10n.settingsScrapeSkipScraped,
      l10n.settingsScrapeSkipScrapedDesc,
      SettingsCategory.scrape.icon,
    ),
    _SearchEntry(
      SettingsCategory.scrape,
      l10n.settingsSectionScrapeAdvanced,
      '',
      SettingsCategory.scrape.icon,
    ),
    _SearchEntry(
      SettingsCategory.scrape,
      l10n.settingsScrapeWorkers,
      '',
      SettingsCategory.scrape.icon,
    ),
    _SearchEntry(
      SettingsCategory.scrape,
      l10n.settingsScrapeBatch,
      '',
      SettingsCategory.scrape.icon,
    ),
    _SearchEntry(
      SettingsCategory.scrape,
      l10n.settingsScrapeRetries,
      '',
      SettingsCategory.scrape.icon,
    ),
    _SearchEntry(
      SettingsCategory.scrape,
      l10n.settingsSectionScrapeProgress,
      '',
      SettingsCategory.scrape.icon,
    ),
    _SearchEntry(
      SettingsCategory.scrape,
      l10n.settingsSectionScrapeOrganize,
      '',
      SettingsCategory.scrape.icon,
    ),
    _SearchEntry(
      SettingsCategory.storage,
      l10n.settingsSectionFileLocation,
      '',
      SettingsCategory.storage.icon,
    ),
    _SearchEntry(
      SettingsCategory.storage,
      l10n.settingsDataDir,
      '',
      SettingsCategory.storage.icon,
    ),
    _SearchEntry(
      SettingsCategory.storage,
      l10n.settingsLibraryDb,
      '',
      SettingsCategory.storage.icon,
    ),
    _SearchEntry(
      SettingsCategory.storage,
      l10n.settingsUserDb,
      '',
      SettingsCategory.storage.icon,
    ),
    _SearchEntry(
      SettingsCategory.storage,
      l10n.settingsHistoryDb,
      '',
      SettingsCategory.storage.icon,
    ),
  ];

  /// 搜索索引 = 精选条目（去重/去掉失效锚点）+ 自动补齐 + 快捷键动作。
  ///
  /// - 精选条目若标题已不存在（改造后改名/删除），或 anchor 指向不存在的
  ///   标题，则丢弃——避免「搜得到但跳不过去」；
  /// - 自动条目覆盖精选之外的其余设置项，图标沿用分类图标；
  /// - 快捷键标题由 [ShortcutAction] 动态生成，单独追加。
  List<_SearchEntry> _buildSearchIndex(AppLocalizations l10n) {
    final auto = _autoSearchIndex(l10n);
    final autoTitles = <String>{for (final e in auto) e.title};
    final curated = _curatedSearchIndex(l10n).where((e) {
      final target = e.anchor ?? e.title;
      return autoTitles.contains(target);
    }).toList();
    final covered = <String>{
      for (final e in curated) '${e.category.name}\u0000${e.title}',
    };
    return [
      ...curated,
      for (final e in auto)
        if (!covered.contains('${e.category.name}\u0000${e.title}')) e,
      for (final a in ShortcutAction.values)
        _SearchEntry(
          SettingsCategory.shortcuts,
          shortcutActionLabel(l10n, a),
          l10n.shortcutHintEdit,
          SettingsCategory.shortcuts.icon,
        ),
    ];
  }

  Widget _buildCategoryItem(
    ColorScheme scheme,
    SettingsCategory cat,
    AppLocalizations l10n,
    SidebarNavStyle navStyle,
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
                        color: !navStyle.slidingIndicator && selected
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
                        Flexible(
                          child: Text(
                            cat.label(l10n),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: selected
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              color: selected
                                  ? scheme.primary
                                  : scheme.onSurface,
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
            child: InkClip(
              child: SingleChildScrollView(
                controller: _contentScrollCtrl,
                child: switch (_category) {
                  SettingsCategory.appearance => const AppearanceSection(),
                  SettingsCategory.playback => const PlaybackSection(),
                  SettingsCategory.audioEffects => const AudioEffectsSection(),
                  SettingsCategory.shortcuts => const ShortcutsSection(),
                  SettingsCategory.lyrics => const LyricsSection(),
                  SettingsCategory.preset => const PresetSection(),
                  SettingsCategory.render => const RenderSection(),
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
                  SettingsCategory.searchIndex => const SearchSection(),
                  SettingsCategory.mediaSource => StreamingServerList(),
                  SettingsCategory.experimentalSource =>
                    const ExperimentalSourceSection(),
                  SettingsCategory.mcp => const McpSection(),
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
    final downloadModule = ref.watch(appPrefsProvider).downloadModuleEnabled;
    final index = _buildSearchIndex(l10n)
        .where((e) => e.category.visible(devMode, downloadModule))
        .toList();
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
              l10n.settingsSearchNoResult(query: _query),
              style: TextStyle(
                fontSize: 13,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      );
    }
    return InkClip(
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.settingsSearchMatchCount(count: matches.length),
              style: TextStyle(
                fontSize: 11,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(height: 8),
            for (final cat in SettingsCategory.values)
              if (cat.visible(devMode, downloadModule) &&
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
          onTap: () => _jumpToSearchEntry(e),
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
                      if (e.subtitle.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          e.subtitle,
                          style: TextStyle(
                            fontSize: 11,
                            color: scheme.onSurfaceVariant.withValues(
                              alpha: 0.7,
                            ),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
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

/// 搜索命中的设置行高亮：在目标位置脉冲 [SettingsDialog] 设置的高亮框。
///
/// 只画描边 + 淡填充、不拦截指针事件；3 次脉冲后由外层清掉 [Rect] 移除。
class SettingsRowFlash extends StatelessWidget {
  const SettingsRowFlash({
    super.key,
    required this.animation,
    required this.color,
  });

  final Animation<double> animation;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final t = animation.value.clamp(0.0, 1.0);
        // 每个周期 0 → 1 → 0；t=1 时相位归零，强度自然回到 0。
        final phase = (t * _SettingsDialogState._flashPulses) % 1.0;
        final intensity = math.sin(phase * math.pi).abs() * (1 - t * 0.2);
        return DecoratedBox(
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.10 * intensity),
            border: Border.all(
              color: color.withValues(alpha: 0.9 * intensity),
              width: 1.6,
            ),
            borderRadius: BorderRadius.circular(AppRadius.control),
          ),
        );
      },
    );
  }
}

/// 不构建滚动条（隐藏滚动条的列表仍可滚轮 / 拖拽滚动）。
class _NoScrollbarBehavior extends ScrollBehavior {
  const _NoScrollbarBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }
}
