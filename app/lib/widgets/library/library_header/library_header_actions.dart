// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../library_header.dart';

extension _LibraryHeaderActions on LibraryHeader {
  /// 「播放全部」：列表只驻留当前分页窗口，故此处按当前搜索条件向 DB 取
  /// 全量（不含 lyrics）一次性建队列（队列本就需要全量）。
  Future<void> _playAll(BuildContext context, WidgetRef ref) async {
    final l10n = context.l10n;
    final rows = await ref.read(libraryStoreProvider.notifier).allTracks();
    if (rows.isEmpty) return;
    final tracks = rows.map(trackFromRow).toList();
    if (!context.mounted) return;
    try {
      ref.read(playbackProvider.notifier).playQueue(tracks);
    } catch (e) {
      _toast(context, l10n.toastPlayFailed('$e'));
    }
  }

  /// 刮削简化入口：运行中 → 取消；空闲 → 立即刮削。
  /// 目录取偏好配置，留空跟随媒体库扫描目录；数据源开关在
  /// 设置 → 刮削 中详细配置（这里用偏好默认值）。
  void _toggleScrape(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final notifier = ref.read(scrapeControllerProvider.notifier);
    if (ref.read(scrapeControllerProvider).scraping) {
      notifier.cancel();
      return;
    }
    final prefs = ref.read(appPrefsProvider);
    var dirs = prefs.scrapeDirs;
    if (dirs.isEmpty) dirs = scanDirs();
    if (dirs.isEmpty) {
      _toast(context, l10n.toastScrapeNoDirs);
      return;
    }
    notifier.start(
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
    _toast(context, l10n.toastScrapeStarted);
  }

  /// 「仅整理」简化入口（不联网，按模板整理目录）：运行中不可重复触发。
  /// 目录取偏好配置，留空跟随媒体库扫描目录；目标/模板沿用设置 → 刮削 的
  /// 组织整理配置（organizeTargetDir / organizePattern），未设目标回退媒体库目录。
  void _startOrganizeFromHeader(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final scrape = ref.read(scrapeControllerProvider);
    if (scrape.scraping) return; // 菜单已禁用运行中触发，此处兜底
    final prefs = ref.read(appPrefsProvider);
    var dirs = prefs.scrapeDirs;
    if (dirs.isEmpty) dirs = scanDirs();
    if (dirs.isEmpty) {
      _toast(context, l10n.toastOrganizeNoDirs);
      return;
    }
    final customTarget = prefs.scrapeOrganizeTargetDir.trim();
    final target = customTarget.isEmpty ? defaultMusicDir() : customTarget;
    if (target.isEmpty) {
      _toast(context, l10n.settingsOrganizeNoTarget);
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
    _toast(
      context,
      customTarget.isEmpty
          ? l10n.settingsOrganizeUsingDefault(target)
          : l10n.toastOrganizeStarted,
    );
  }

  /// 全量扫描：确认后清空曲库重建（删除 DB 记录，不删除源文件）。
  Future<void> _startFullScan(
    BuildContext context,
    WidgetRef ref,
    LibraryState state,
  ) async {
    final l10n = context.l10n;
    if (state.scanning || state.scanDirs.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.libraryFullScanConfirm),
        content: Text(l10n.libraryFullScanConfirmDesc),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.libraryFullScan),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    ref.read(libraryStoreProvider.notifier).startScan(incremental: false);
  }

  void _openFolders(BuildContext context) {
    final l10n = context.l10n;
    SDialog.show(
      context,
      title: l10n.libraryScanDirs,
      description: l10n.libraryScanDirsDesc,
      child: const FolderManager(),
      actions: [
        SButton(
          label: l10n.commonDone,
          variant: SButtonVariant.secondary,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }

  void _openMediaStats(BuildContext context, LibraryState state) {
    final l10n = context.l10n;
    SDialog.show(
      context,
      title: l10n.libraryMediaStats,
      description: l10n.libraryMediaStatsDesc,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildLibraryHeaderStatRow(
            context,
            l10n.libraryStatTracks,
            l10n.libraryStatTrackCount(state.totalCount),
          ),
          _buildLibraryHeaderStatRow(
            context,
            l10n.libraryStatDuration,
            _formatDuration(state.totalDurationMs, l10n),
          ),
          _buildLibraryHeaderStatRow(
            context,
            l10n.libraryStatSize,
            _formatSize(state.totalSizeBytes),
          ),
          _buildLibraryHeaderStatRow(
            context,
            l10n.libraryScanDirs,
            l10n.libraryScanDirCount(state.scanDirs.length),
          ),
        ],
      ),
      actions: [
        SButton(
          label: l10n.commonClose,
          variant: SButtonVariant.secondary,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }

  String _formatSize(int bytes) {
    if (bytes <= 0) return '';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var v = bytes.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(v >= 100 ? 0 : 1)} ${units[i]}';
  }

  String _formatDuration(int ms, AppLocalizations l10n) {
    final totalSec = ms ~/ 1000;
    final h = totalSec ~/ 3600;
    final m = (totalSec % 3600) ~/ 60;
    final s = totalSec % 60;
    if (h > 0) return l10n.libraryHoursMinutes(h, m);
    if (m > 0) return l10n.libraryMinutes(m);
    return l10n.librarySeconds(s);
  }

  void _toast(BuildContext context, String msg) {
    if (!context.mounted) return;
    toast(msg);
  }
}
