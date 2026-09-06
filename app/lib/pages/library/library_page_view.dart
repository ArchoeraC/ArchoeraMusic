// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../library_page.dart';

extension _LibraryPageView on _LibraryPageState {
  Widget _buildLibraryPage(BuildContext context) {
    final state = ref.watch(libraryStoreProvider);
    // 选择性订阅（播放位置/FFT 50ms 更新不重建列表）
    final playingId = ref.watch(playbackProvider.select((s) => s.trackId));
    final isPlaying = ref.watch(playbackProvider.select((s) => s.playing));
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    final tracks = state.filteredTracks.map(trackFromRow).toList();

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
                      Icons.error_outline,
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
          else if (state.initialized && state.tracks.isEmpty)
            Expanded(
              child: LibraryEmptyState(
                hasDirs: state.scanDirs.isNotEmpty,
                scanning: state.scanning,
                onAddFolder: () => _handleEmptyAddFolder(state),
              ),
            )
          else if (tracks.isEmpty && state.searchQuery.isNotEmpty)
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
                items: tracks,
                playingId: playingId,
                isPlaying: isPlaying,
                showAlbum: true,
                showDuration: true,
                onPlay: _play,
                onContextMenu: _onTrackMenu,
              ),
            ),
        ],
      ),
    );
  }
}
