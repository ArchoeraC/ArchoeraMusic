// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../history_page.dart';

extension _HistoryPageView on _HistoryPageState {
  Widget _buildHistoryPage(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;
    // 选择性订阅（播放位置/FFT 50ms 更新不重建列表）
    final playingId = ref.watch(playbackProvider.select((s) => s.trackId));
    final isPlaying = ref.watch(playbackProvider.select((s) => s.playing));
    final hasHistory = _entries.isNotEmpty;

    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── 标题 ─────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.sidebarHistory,
                        style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                          color: scheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        hasHistory
                            ? l10n.commonSongCountHint(_entries.length)
                            : l10n.pageHistorySubtitleEmpty,
                        style: TextStyle(
                          fontSize: 13,
                          color: scheme.onSurfaceVariant.withValues(
                            alpha: 0.75,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                if (hasHistory) ...[
                  SButton(
                    label: l10n.commonPlayAll,
                    icon: EtaIcons.play,
                    variant: SButtonVariant.primary,
                    onPressed: _playAll,
                  ),
                  const SizedBox(width: 10),
                  SButton(
                    label: l10n.commonClear,
                    icon: EtaIcons.deleteOutline,
                    variant: SButtonVariant.secondary,
                    onPressed: _confirmClear,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          const Divider(height: 1),
          // ── 内容区 ───────────────────────────────────────────
          Expanded(
            child: _loading
                ? const Center(
                    child: SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    ),
                  )
                : !hasHistory
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          EtaIcons.history,
                          size: 48,
                          color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          l10n.pageHistoryEmpty,
                          style: theme.textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          l10n.pageHistoryEmptyHint,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  )
                : SongList(
                    items: _tracks,
                    playingId: playingId,
                    isPlaying: isPlaying,
                    onPlay: _playTrack,
                    onContextMenu: _onRowMenu,
                  ),
          ),
        ],
      ),
    );
  }
}
