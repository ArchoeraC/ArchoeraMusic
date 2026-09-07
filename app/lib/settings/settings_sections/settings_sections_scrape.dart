// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../settings_sections.dart';

// ── 刮削 ──────────────────────────────────────────────────────────────

/// 刮削分类：目录（留空跟随媒体库扫描目录）+ 数据源开关 + 进度统计 +
/// 立即刮削/取消。
class ScrapeSection extends ConsumerStatefulWidget {
  const ScrapeSection({super.key});

  @override
  ConsumerState<ScrapeSection> createState() => _ScrapeSectionState();
}

class _ScrapeSectionState extends ConsumerState<ScrapeSection> {
  late final TextEditingController _scrapeDirsCtrl;
  late final TextEditingController _organizeTargetCtrl;
  late final TextEditingController _organizePatternCtrl;

  @override
  void initState() {
    super.initState();
    final p = ref.read(appPrefsProvider);
    _scrapeDirsCtrl = TextEditingController(text: p.scrapeDirs.join('\n'));
    _organizeTargetCtrl = TextEditingController(
      text: p.scrapeOrganizeTargetDir,
    );
    _organizePatternCtrl = TextEditingController(text: p.scrapeOrganizePattern);
  }

  @override
  void dispose() {
    _scrapeDirsCtrl.dispose();
    _organizeTargetCtrl.dispose();
    _organizePatternCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    final prefs = ref.watch(appPrefsProvider);
    final notifier = ref.read(appPrefsProvider.notifier);
    final scrape = ref.watch(scrapeControllerProvider);
    final scraper = ref.read(scrapeControllerProvider.notifier);
    final dirs = prefs.scrapeDirs.isNotEmpty ? prefs.scrapeDirs : scanDirs();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingSection(
          title: l10n.settingsSectionScrapeDirs,
          note: dirs.isEmpty
              ? l10n.settingsScrapeDirsEmptyNote
              : l10n.settingsScrapeDirsNote(dirs.join(' ; ')),
          children: [
            SettingPathFieldCard(
              icon: EtaIcons.folderOutline,
              ctrl: _scrapeDirsCtrl,
              hint: l10n.settingsScrapeDirsHint,
              save: (v) => _saveScrapeDirs(v, l10n),
              restoreDefault: () => '',
            ),
          ],
        ),
        const SizedBox(height: 20),
        SettingSection(
          title: l10n.settingsSectionScrapeSources,
          children: [
            SettingSwitchTile(
              icon: EtaIcons.earth,
              title: l10n.settingsScrapeSourceMusicBrainz,
              subtitle: l10n.settingsScrapeSourceDesc,
              value: prefs.scrapeUseMusicBrainz,
              onChanged: (v) => notifier.setScrape(useMusicBrainz: v),
            ),
            SettingSwitchTile(
              icon: EtaIcons.playlist,
              title: l10n.settingsScrapeSourceDeezer,
              subtitle: l10n.settingsScrapeSourceDesc,
              value: prefs.scrapeUseDeezer,
              onChanged: (v) => notifier.setScrape(useDeezer: v),
            ),
            SettingSwitchTile(
              icon: EtaIcons.storeOutline,
              title: l10n.settingsScrapeSourceItunes,
              subtitle: l10n.settingsScrapeSourceDesc,
              value: prefs.scrapeUseItunes,
              onChanged: (v) => notifier.setScrape(useItunes: v),
            ),
            SettingSwitchTile(
              icon: EtaIcons.musicOutline,
              title: l10n.settingsScrapeSourceNetease,
              subtitle: l10n.settingsScrapeSourceDesc,
              value: prefs.scrapeUseNetease,
              onChanged: (v) => notifier.setScrape(useNetease: v),
            ),
            SettingSwitchTile(
              icon: EtaIcons.music2Outline,
              title: l10n.settingsScrapeSourceQQMusic,
              subtitle: l10n.settingsScrapeSourceDesc,
              value: prefs.scrapeUseQQMusic,
              onChanged: (v) => notifier.setScrape(useQQMusic: v),
            ),
            SettingSwitchTile(
              icon: EtaIcons.headphoneOutline,
              title: l10n.settingsScrapeSourceKugou,
              subtitle: l10n.settingsScrapeSourceDesc,
              value: prefs.scrapeUseKugou,
              onChanged: (v) => notifier.setScrape(useKugou: v),
            ),
            SettingSwitchTile(
              icon: EtaIcons.soundLineOutline,
              title: l10n.settingsScrapeSourceKuwo,
              subtitle: l10n.settingsScrapeSourceDesc,
              value: prefs.scrapeUseKuwo,
              onChanged: (v) => notifier.setScrape(useKuwo: v),
            ),
            SettingSwitchTile(
              icon: EtaIcons.shareForwardOutline,
              title: l10n.settingsScrapeSourceMigu,
              subtitle: l10n.settingsScrapeSourceDesc,
              value: prefs.scrapeUseMigu,
              onChanged: (v) => notifier.setScrape(useMigu: v),
            ),
            SettingSwitchTile(
              icon: EtaIcons.fingerprint,
              title: l10n.settingsScrapeSourceAcoustID,
              subtitle: l10n.settingsScrapeSourceDesc,
              value: prefs.scrapeUseAcoustID,
              onChanged: (v) => notifier.setScrape(useAcoustID: v),
            ),
          ],
        ),
        const SizedBox(height: 20),
        SettingSection(
          title: l10n.settingsSectionScrapeWrite,
          children: [
            SettingSwitchTile(
              icon: EtaIcons.musicOutline,
              title: l10n.settingsScrapeEmbedMetadata,
              subtitle: l10n.settingsScrapeWriteDesc,
              value: prefs.scrapeEmbedMetadata,
              onChanged: (v) => notifier.setScrape(embedMetadata: v),
            ),
            SettingSwitchTile(
              icon: EtaIcons.picOutline,
              title: l10n.settingsScrapeEmbedCover,
              subtitle: l10n.settingsScrapeWriteDesc,
              value: prefs.scrapeEmbedCover,
              onChanged: (v) => notifier.setScrape(embedCover: v),
            ),
            SettingSwitchTile(
              icon: EtaIcons.fileMusicOutline,
              title: l10n.settingsScrapeEmbedLyrics,
              subtitle: l10n.settingsScrapeWriteDesc,
              value: prefs.scrapeEmbedLyrics,
              onChanged: (v) => notifier.setScrape(embedLyrics: v),
            ),
            SettingSwitchTile(
              icon: EtaIcons.listCheck3Outline,
              title: l10n.settingsScrapeSkipScraped,
              subtitle: l10n.settingsScrapeSkipScrapedDesc,
              value: prefs.scrapeSkipScraped,
              onChanged: (v) => notifier.setScrape(skipScraped: v),
            ),
          ],
        ),
        const SizedBox(height: 20),
        SettingSection(
          title: l10n.settingsSectionScrapeAdvanced,
          children: [
            SettingSliderTile(
              icon: EtaIcons.chipOutline,
              title: l10n.settingsScrapeWorkers,
              subtitle: l10n.settingsScrapeWorkersDesc(
                prefs.scrapeWorkers <= 0
                    ? l10n.settingsValueAuto
                    : '${prefs.scrapeWorkers}',
              ),
              value: prefs.scrapeWorkers.toDouble().clamp(0, 8),
              min: 0,
              max: 8,
              divisions: 8,
              onChanged: (v) => notifier.setScrape(workers: v.round()),
            ),
            SettingSliderTile(
              icon: EtaIcons.menuOutline,
              title: l10n.settingsScrapeBatch,
              subtitle: l10n.settingsScrapeBatchDesc(
                '${prefs.scrapeBatchSize}',
              ),
              value: prefs.scrapeBatchSize.toDouble().clamp(1, 64),
              min: 1,
              max: 64,
              divisions: 63,
              onChanged: (v) => notifier.setScrape(batchSize: v.round()),
            ),
            SettingSliderTile(
              icon: EtaIcons.refresh,
              title: l10n.settingsScrapeRetries,
              subtitle: l10n.settingsScrapeRetriesDesc(
                '${prefs.scrapeMaxRetries}',
              ),
              value: prefs.scrapeMaxRetries.toDouble().clamp(0, 10),
              min: 0,
              max: 10,
              divisions: 10,
              onChanged: (v) => notifier.setScrape(maxRetries: v.round()),
            ),
          ],
        ),
        const SizedBox(height: 20),
        _buildOrganizeSection(scheme, l10n, prefs, notifier, scrape),
        if (!scrape.organize) ...[
          const SizedBox(height: 20),
          SettingSection(
            title: l10n.settingsSectionScrapeProgress,
            children: [
              _buildScrapeStatus(scheme, l10n, scrape, dirs.isNotEmpty),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                child: scrape.scraping
                    ? SButton(
                        label: l10n.settingsScrapeCancel,
                        icon: EtaIcons.stop,
                        variant: SButtonVariant.error,
                        onPressed: scraper.cancel,
                      )
                    : SButton(
                        label: l10n.settingsScrapeStart,
                        icon: EtaIcons.magic3,
                        variant: SButtonVariant.primary,
                        onPressed: _startScrape,
                      ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildOrganizeSection(
    ColorScheme scheme,
    AppLocalizations l10n,
    AppPrefs prefs,
    AppPrefsNotifier notifier,
    ScrapeState scrape,
  ) {
    final organizeRunning = scrape.organize && scrape.scraping;
    final organizeDone =
        scrape.organize && !scrape.scraping && scrape.hasActivity;
    return SettingSection(
      title: l10n.settingsSectionScrapeOrganize,
      note: l10n.settingsScrapeOrganizeNote,
      children: [
        if (organizeRunning || organizeDone)
          _buildOrganizeStatus(scheme, l10n, scrape, organizeRunning)
        else ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 2),
            child: Text(
              l10n.settingsScrapeOrganizeTargetDir,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
          ),
          SettingPathFieldCard(
            icon: EtaIcons.foldersOutline,
            ctrl: _organizeTargetCtrl,
            hint: l10n.settingsScrapeOrganizeTargetHint,
            save: (v) => notifier.setScrape(organizeTargetDir: v.trim()),
            restoreDefault: () => '',
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 2),
            child: Text(
              l10n.settingsScrapeOrganizePattern,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
          ),
          SettingPathFieldCard(
            icon: EtaIcons.sitemapOutline,
            ctrl: _organizePatternCtrl,
            hint: l10n.settingsScrapeOrganizePatternHint,
            save: (v) => notifier.setScrape(organizePattern: v.trim()),
            restoreDefault: () => kScrapeOrganizePatternDefault,
          ),
          _buildOrganizePresets(l10n, notifier),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 14),
            child: SButton(
              label: l10n.settingsScrapeOrganizeStart,
              icon: EtaIcons.fileImportOutline,
              variant: SButtonVariant.secondary,
              onPressed: () => _startOrganize(l10n),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildOrganizePresets(
    AppLocalizations l10n,
    AppPrefsNotifier notifier,
  ) {
    final presets = <(String, String)>[
      (
        l10n.settingsScrapeOrganizePresetArtistAlbum,
        '{artist}/{album}/{track}. {title}.{ext}',
      ),
      (l10n.settingsScrapeOrganizePresetArtistOnly, '{artist}/{title}.{ext}'),
      (
        l10n.settingsScrapeOrganizePresetGenreArtistAlbum,
        '{genre}/{artist}/{album}/{track}. {title}.{ext}',
      ),
      (
        l10n.settingsScrapeOrganizePresetYearArtistAlbum,
        '{year}/{artist}/{album}/{track}. {title}.{ext}',
      ),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          for (final p in presets)
            ActionChip(
              visualDensity: VisualDensity.compact,
              label: Text(p.$1, style: const TextStyle(fontSize: 11)),
              onPressed: () {
                _organizePatternCtrl.text = p.$2;
                notifier.setScrape(organizePattern: p.$2);
              },
            ),
        ],
      ),
    );
  }

  Widget _buildOrganizeStatus(
    ColorScheme scheme,
    AppLocalizations l10n,
    ScrapeState scrape,
    bool running,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (running) ...[
            if (scrape.percent != null) ...[
              LinearProgressIndicator(
                value: scrape.percent,
                minHeight: 4,
                borderRadius: BorderRadius.circular(2),
              ),
              const SizedBox(height: 8),
            ],
            Text(
              scrape.current.isEmpty
                  ? l10n.settingsOrganizeRunning
                  : scrape.current,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
            ),
          ] else
            Text(
              scrape.error != null
                  ? scrape.error!
                  : l10n.settingsOrganizeDone(
                      scrape.success,
                      scrape.skipped,
                      scrape.failed,
                    ),
              style: TextStyle(
                fontSize: 12.5,
                color: scrape.error != null
                    ? scheme.error
                    : scheme.onSurfaceVariant,
              ),
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 14,
            runSpacing: 4,
            children: [
              _statChip(
                scheme,
                scheme.primary,
                l10n.settingsOrganizeMoved,
                scrape.success,
              ),
              _statChip(
                scheme,
                scheme.onSurfaceVariant,
                l10n.settingsOrganizeSkipped,
                scrape.skipped,
              ),
              _statChip(
                scheme,
                scheme.error,
                l10n.settingsOrganizeFailed,
                scrape.failed,
              ),
            ],
          ),
          if (running) ...[
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerRight,
              child: SButton(
                label: l10n.settingsOrganizeCancel,
                icon: EtaIcons.stop,
                size: SButtonSize.small,
                variant: SButtonVariant.error,
                onPressed: ref.read(scrapeControllerProvider.notifier).cancel,
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _startOrganize(AppLocalizations l10n) {
    final prefs = ref.read(appPrefsProvider);
    var dirs = prefs.scrapeDirs;
    if (dirs.isEmpty) dirs = scanDirs();
    if (dirs.isEmpty) {
      toast(l10n.toastOrganizeNoDirs);
      return;
    }
    final customTarget = prefs.scrapeOrganizeTargetDir.trim();
    final target = customTarget.isEmpty ? defaultMusicDir() : customTarget;
    if (target.isEmpty) {
      toast(l10n.settingsOrganizeNoTarget);
      return;
    }
    ref
        .read(scrapeControllerProvider.notifier)
        .startOrganize(
          dirs: dirs,
          dbPath: '${resolveDataDir()}/scraper-state.db',
          targetDir: target,
          pattern: prefs.scrapeOrganizePattern,
        );
    if (customTarget.isEmpty) {
      toast(l10n.settingsOrganizeUsingDefault(target));
    } else {
      toast(l10n.toastOrganizeStarted);
    }
  }

  Widget _buildScrapeStatus(
    ColorScheme scheme,
    AppLocalizations l10n,
    ScrapeState scrape,
    bool dirsReady,
  ) {
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
            Wrap(
              spacing: 14,
              runSpacing: 4,
              children: [
                _statChip(
                  scheme,
                  scheme.primary,
                  l10n.settingsScrapeSuccess,
                  scrape.success,
                ),
                _statChip(
                  scheme,
                  scheme.error,
                  l10n.settingsScrapeFailed,
                  scrape.failed,
                ),
                _statChip(
                  scheme,
                  scheme.onSurfaceVariant,
                  l10n.settingsScrapeSkipped,
                  scrape.skipped,
                ),
                _statChip(
                  scheme,
                  scheme.tertiary,
                  l10n.settingsScrapeNotFound,
                  scrape.notFound,
                ),
              ],
            ),
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
            Wrap(
              spacing: 14,
              runSpacing: 4,
              children: [
                _statChip(
                  scheme,
                  scheme.primary,
                  l10n.settingsScrapeSuccess,
                  scrape.success,
                ),
                _statChip(
                  scheme,
                  scheme.error,
                  l10n.settingsScrapeFailed,
                  scrape.failed,
                ),
                _statChip(
                  scheme,
                  scheme.onSurfaceVariant,
                  l10n.settingsScrapeSkipped,
                  scrape.skipped,
                ),
                _statChip(
                  scheme,
                  scheme.tertiary,
                  l10n.settingsScrapeNotFound,
                  scrape.notFound,
                ),
              ],
            ),
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
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
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
      ],
    );
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
    ref
        .read(scrapeControllerProvider.notifier)
        .start(
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
}
