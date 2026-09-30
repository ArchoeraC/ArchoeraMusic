// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../library_page.dart';

extension _LibraryPageView on _LibraryPageState {
  Widget _buildLibraryPage(BuildContext context) {
    final state = ref.watch(libraryStoreProvider);
    final notifier = ref.read(libraryStoreProvider.notifier);
    // 选择性订阅（播放位置/FFT 50ms 更新不重建列表）
    final playingId = ref.watch(playbackProvider.select((s) => s.trackId));
    final isPlaying = ref.watch(playbackProvider.select((s) => s.playing));
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;

    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const LibraryHeader(),
          const Divider(height: 1),
          // ── 曲目列表 / 空状态 ─────────────────────────────────
          if (state.error != null)
            Expanded(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      EtaIcons.alertOutline,
                      size: 40,
                      color: scheme.error.withValues(alpha: 0.6),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      state.error!,
                      style: TextStyle(
                        fontSize: 13,
                        color: scheme.onSurfaceVariant,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            )
          else if (state.initialized &&
              state.totalCount == 0 &&
              state.searchQuery.isEmpty)
            Expanded(
              child: LibraryEmptyState(
                hasDirs: state.scanDirs.isNotEmpty,
                scanning: state.scanning,
                onAddFolder: () => _handleEmptyAddFolder(state),
              ),
            )
          else if (state.totalCount == 0 && state.searchQuery.isNotEmpty)
            Expanded(
              child: Center(
                child: Text(
                  l10n.libraryNoMatch,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            )
          else
            Expanded(
              child: SongList(
                key: const PageStorageKey('page.library'),
                // 窗口模式：items 传空，由 totalCount + itemAt 按全局 index
                // 映射到有界页缓存；未驻留页渲染占位并触发异步取页。
                items: const [],
                totalCount: state.totalCount,
                itemAt: (index) {
                  final row = notifier.rowAt(index);
                  return row == null ? null : trackFromRow(row);
                },
                onMissingIndex: notifier.ensureIndex,
                playingIndexOverride: notifier.playingIndexOf(playingId),
                playingId: playingId,
                isPlaying: isPlaying,
                showAlbum: true,
                showDuration: true,
                onPlay: _play,
                onContextMenu: _onTrackMenu,
                onReachBottom: () => notifier.loadMore(),
                hasMore: state.hasMore,
                loadingMore: state.loadingMore,
                // 「全选」= 全库（当前搜索条件），批量操作按全量执行；
                // UI 仍只渲染分页窗口，全量仅在批量模式期间驻留。
                loadAllItems: () async {
                  final rows = await notifier.allTracks();
                  return rows.map(trackFromRow).toList();
                },
              ),
            ),
        ],
      ),
    );
  }
}
