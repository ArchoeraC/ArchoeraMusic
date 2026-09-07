// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../library_header.dart';

extension _LibraryHeaderView on LibraryHeader {
  Widget _buildLibraryHeader(BuildContext context, WidgetRef ref) {
    final state = ref.watch(libraryStoreProvider);
    final scrape = ref.watch(scrapeControllerProvider);
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    final notifier = ref.read(libraryStoreProvider.notifier);
    final tracks = state.filteredTracks.map(trackFromRow).toList();

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题 + 统计 / 扫描进度
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                l10n.sidebarLibrary,
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(width: 14),
              _buildStatus(context, state, scheme, l10n),
            ],
          ),
          const SizedBox(height: 14),
          // 操作行 + 搜索
          Row(
            children: [
              SButton(
                label: l10n.commonPlayAll,
                icon: EtaIcons.play,
                variant: SButtonVariant.primary,
                onPressed: tracks.isEmpty
                    ? null
                    : () => _playAll(context, ref, tracks),
              ),
              const SizedBox(width: 8),
              // 扫描（旋转动画）
              SizedBox(
                width: 36,
                height: 36,
                child: AnimatedRotation(
                  turns: state.scanning ? 1 : 0,
                  duration: animDuration(
                    context,
                    const Duration(milliseconds: 400),
                  ),
                  curve: Curves.linear,
                  child: SButton(
                    label: '',
                    circle: true,
                    icon: EtaIcons.refresh,
                    variant: SButtonVariant.secondary,
                    onPressed: state.scanning
                        ? notifier.cancelScan
                        : (state.scanDirs.isEmpty
                              ? null
                              : () => notifier.startScan()),
                    loading: state.scanning,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // 刮削（简化入口：运行中变停止按钮可取消；详细参数见设置 → 刮削）
              SizedBox(
                width: 36,
                height: 36,
                child: SButton(
                  label: '',
                  circle: true,
                  icon: scrape.scraping ? EtaIcons.stop : EtaIcons.magic3,
                  variant: scrape.scraping
                      ? SButtonVariant.error
                      : SButtonVariant.secondary,
                  onPressed: () => _toggleScrape(context, ref),
                ),
              ),
              const SizedBox(width: 8),
              _buildMoreMenu(context, ref, state, scrape.scraping, l10n),
              const Spacer(),
              SInput(
                width: 190,
                hintText: l10n.librarySearchHint,
                prefixIcon: EtaIcons.search2,
                clearable: true,
                onChanged: (q) => notifier.setSearchQuery(q),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 标题旁的状态区：扫描进度 / 曲目统计（对齐原项目 Transition 切换）。
  Widget _buildStatus(
    BuildContext context,
    LibraryState state,
    ColorScheme scheme,
    AppLocalizations l10n,
  ) {
    final Widget child;
    if (state.scanning) {
      final percent = state.scanPercent;
      child = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 13,
            height: 13,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Text(
            percent == null
                ? (state.scanCurrent.isEmpty
                      ? l10n.libraryScanningFiles
                      : state.scanCurrent)
                : '${(percent * 100).toStringAsFixed(0)}%'
                      ' · ${state.scanned}/${state.total}',
            style: TextStyle(
              fontSize: 13,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.75),
            ),
          ),
        ],
      );
    } else if (state.initialized && state.tracks.isNotEmpty) {
      final size = _formatSize(state.totalSizeBytes);
      child = Text(
        l10n.libraryTrackCount(
          state.tracks.length,
          size.isEmpty ? '' : ' · $size',
        ),
        style: TextStyle(
          fontSize: 13,
          color: scheme.onSurfaceVariant.withValues(alpha: 0.75),
        ),
      );
    } else {
      child = const SizedBox.shrink();
    }
    return AnimatedSwitcher(
      duration: animDuration(context, const Duration(milliseconds: 200)),
      child: child,
    );
  }

  Widget _buildMoreMenu(
    BuildContext context,
    WidgetRef ref,
    LibraryState state,
    bool scrapeBusy,
    AppLocalizations l10n,
  ) {
    return PopupMenuButton<String>(
      tooltip: l10n.commonMore,
      position: PopupMenuPosition.under,
      offset: const Offset(0, 4),
      // 性能模式：菜单直出，无淡入/弹出动效
      popUpAnimationStyle: noAnim(context) ? AnimationStyle.noAnimation : null,
      onSelected: (key) {
        switch (key) {
          case 'folders':
            _openFolders(context);
            break;
          case 'fullScan':
            _startFullScan(context, ref, state);
            break;
          case 'organize':
            _startOrganizeFromHeader(context, ref);
            break;
          case 'stats':
            _openMediaStats(context, state);
            break;
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 'fullScan',
          height: 40,
          enabled: !state.scanning && state.scanDirs.isNotEmpty,
          child: Row(
            children: [
              const Icon(EtaIcons.search3, size: 17),
              const SizedBox(width: 10),
              Text(l10n.libraryFullScan),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'organize',
          height: 40,
          enabled: !scrapeBusy,
          child: Row(
            children: [
              const Icon(EtaIcons.fileImportOutline, size: 17),
              const SizedBox(width: 10),
              Text(l10n.settingsScrapeOrganizeStart),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'folders',
          height: 40,
          child: Row(
            children: [
              const Icon(EtaIcons.folderOutline, size: 17),
              const SizedBox(width: 10),
              Text(l10n.libraryScanDirs),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'stats',
          height: 40,
          child: Row(
            children: [
              const Icon(EtaIcons.chartPieOutline, size: 17),
              const SizedBox(width: 10),
              Text(l10n.libraryMediaStats),
            ],
          ),
        ),
      ],
      child: const SizedBox(
        width: 36,
        height: 36,
        child: Center(child: Icon(EtaIcons.dots, size: 20)),
      ),
    );
  }
}

Widget _buildLibraryHeaderStatRow(
  BuildContext context,
  String label,
  String value,
) {
  final scheme = Theme.of(context).colorScheme;
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(fontSize: 13.5, color: scheme.onSurfaceVariant),
          ),
        ),
        Text(
          value,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ],
    ),
  );
}
