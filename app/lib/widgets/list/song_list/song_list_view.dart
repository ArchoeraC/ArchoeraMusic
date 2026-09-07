// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../song_list.dart';

extension _SongListView on _SongListState {
  Widget _buildSongList(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return Stack(
      children: [
        Column(
          children: [
            _SongListHeader(
              batchActive: _batchActive,
              items: widget.items,
              selected: _selected,
              selectedCount: _selectedCount,
              showIndex: widget.showIndex,
              showAlbum: widget.showAlbum,
              showDuration: widget.showDuration,
              developerMode: ref.watch(appPrefsProvider).developerMode,
              l10n: l10n,
              scheme: theme.colorScheme,
              onEnterBatch: _enterBatch,
              onSelectAll: _selectAll,
              onClearAll: _clearAll,
              onInvert: _invertSelection,
              onBatchPlay: _batchPlay,
              onBatchAddQueue: _batchAddQueue,
              onBatchDownload: _batchDownload,
              onExitBatch: _exitBatch,
            ),
            const Divider(height: 1),
            Expanded(
              child: NotificationListener<ScrollNotification>(
                onNotification: _onScroll,
                child: ListView.builder(
                  controller: _scrollCtrl,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: widget.items.length + 1,
                  itemBuilder: (context, index) {
                    if (index == widget.items.length) {
                      return _SongListFooter(
                        visible: widget.items.isNotEmpty,
                        loadingMore: widget.loadingMore,
                        hasMore: widget.hasMore,
                      );
                    }
                    final item = widget.items[index];
                    return SongRow(
                      item: item,
                      index: index,
                      showIndex: widget.showIndex,
                      showAlbum: widget.showAlbum,
                      showDuration: widget.showDuration,
                      showSource: widget.showSource,
                      isPlaying: widget.playingId == item.id,
                      playingNow: widget.isPlaying,
                      liked:
                          widget.likedIds?.contains(songLikeKey(item)) ?? false,
                      onPlay: widget.onPlay,
                      onToggleLike: widget.onToggleLike,
                      onContextMenu: widget.onContextMenu,
                      batchActive: _batchActive,
                      selected: _selected.contains(songLikeKey(item)),
                      onToggleSelect: () => _toggleSelect(item),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
        Positioned(
          right: 24,
          bottom: 20,
          child: SongListFloatActions(
            controller: _scrollCtrl,
            playingIndex: _playingIndex,
            itemExtent: _SongListState._songRowExtent,
            topPadding: _SongListState._songTopPadding,
            batchActive: _batchActive,
          ),
        ),
      ],
    );
  }
}

class _SongListHeader extends StatelessWidget {
  const _SongListHeader({
    required this.batchActive,
    required this.items,
    required this.selected,
    required this.selectedCount,
    required this.showIndex,
    required this.showAlbum,
    required this.showDuration,
    required this.developerMode,
    required this.l10n,
    required this.scheme,
    required this.onEnterBatch,
    required this.onSelectAll,
    required this.onClearAll,
    required this.onInvert,
    required this.onBatchPlay,
    required this.onBatchAddQueue,
    required this.onBatchDownload,
    required this.onExitBatch,
  });

  final bool batchActive;
  final List<Track> items;
  final Set<String> selected;
  final int selectedCount;
  final bool showIndex;
  final bool showAlbum;
  final bool showDuration;
  final bool developerMode;
  final AppLocalizations l10n;
  final ColorScheme scheme;
  final VoidCallback onEnterBatch;
  final VoidCallback onSelectAll;
  final VoidCallback onClearAll;
  final VoidCallback onInvert;
  final Future<void> Function() onBatchPlay;
  final VoidCallback onBatchAddQueue;
  final Future<void> Function() onBatchDownload;
  final VoidCallback onExitBatch;

  @override
  Widget build(BuildContext context) {
    if (batchActive) {
      final all = items.isNotEmpty && selectedCount == items.length;
      final none = selectedCount == 0;
      return Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            SizedBox(
              width: 36,
              child: Center(
                child: Checkbox(
                  value: all ? true : (none ? false : null),
                  tristate: true,
                  visualDensity: VisualDensity.compact,
                  onChanged: (v) => v == true ? onSelectAll() : onClearAll(),
                ),
              ),
            ),
            Expanded(
              child: Text(
                l10n.queueTrackCount(selectedCount),
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              ),
            ),
            _SongListIconButton(
              tooltip: l10n.batchInvert,
              icon: EtaIcons.flipHorizontal,
              onTap: onInvert,
            ),
            _SongListIconButton(
              tooltip: l10n.batchPlay,
              icon: EtaIcons.play,
              enabled: !none,
              onTap: () => onBatchPlay(),
            ),
            _SongListIconButton(
              tooltip: l10n.batchAddQueue,
              icon: EtaIcons.playlist,
              enabled: !none,
              onTap: onBatchAddQueue,
            ),
            if (developerMode)
              _SongListIconButton(
                tooltip: l10n.batchDownload,
                icon: EtaIcons.downloadOutline,
                enabled: !none,
                onTap: () => onBatchDownload(),
              ),
            _SongListIconButton(
              tooltip: l10n.batchExit,
              icon: EtaIcons.close,
              onTap: onExitBatch,
            ),
          ],
        ),
      );
    }
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      alignment: Alignment.centerLeft,
      child: Row(
        children: [
          SizedBox(
            width: 28,
            child: Tooltip(
              message: l10n.batchSelectHint,
              child: InkResponse(
                radius: 14,
                onTap: onEnterBatch,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(
                    EtaIcons.listCheck2,
                    size: 16,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
          if (showIndex)
            const SizedBox(
              width: 32,
              child: Text('#', textAlign: TextAlign.center),
            ),
          Expanded(
            child: Text(
              l10n.songListTitle,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ),
          if (showAlbum)
            Expanded(
              child: Text(
                l10n.songListAlbum,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ),
          const SizedBox(width: 28),
          if (showDuration)
            SizedBox(
              width: 64,
              child: Text(l10n.songListDuration, textAlign: TextAlign.center),
            ),
        ],
      ),
    );
  }
}

class _SongListIconButton extends StatelessWidget {
  const _SongListIconButton({
    required this.tooltip,
    required this.icon,
    required this.onTap,
    this.enabled = true,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: IconButton(
        onPressed: enabled ? onTap : null,
        iconSize: 18,
        visualDensity: VisualDensity.compact,
        color: scheme.onSurfaceVariant,
        disabledColor: scheme.onSurfaceVariant.withValues(alpha: 0.3),
        icon: Icon(icon),
      ),
    );
  }
}

class _SongListFooter extends StatelessWidget {
  const _SongListFooter({
    required this.visible,
    required this.loadingMore,
    required this.hasMore,
  });

  final bool visible;
  final bool loadingMore;
  final bool hasMore;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!visible) return const SizedBox.shrink();
    return SizedBox(
      height: 48,
      child: Center(
        child: loadingMore
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : !hasMore
            ? Text(
                context.l10n.commonNoMore,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              )
            : const SizedBox.shrink(),
      ),
    );
  }
}
