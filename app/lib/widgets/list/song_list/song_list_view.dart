// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../song_list.dart';

extension _SongListView on _SongListState {
  Widget _buildSongList(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    // 窗口模式总行数（含未驻留页）；非窗口模式即 items 长度。
    final listCount = widget.totalCount ?? widget.items.length;
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
              downloadModule: ref.watch(appPrefsProvider).downloadModuleEnabled,
              l10n: l10n,
              scheme: theme.colorScheme,
              allSelected: _allSelected,
              onEnterBatch: _enterBatch,
              onSelectAll: () => unawaited(_selectAll()),
              onClearAll: _clearAll,
              onInvert: () => unawaited(_invertSelection()),
              onBatchPlay: _batchPlay,
              onBatchAddQueue: _batchAddQueue,
              onBatchDownload: _batchDownload,
              onBatchEditMetadata: widget.onBatchEditMetadata == null
                  ? null
                  : () => unawaited(_batchEditMetadata()),
              onBatchAddToPlaylist: widget.onBatchAddToPlaylist == null
                  ? null
                  : () => unawaited(_batchAddToPlaylist()),
              onExitBatch: _exitBatch,
            ),
            const Divider(height: 1),
            Expanded(
              child: NotificationListener<ScrollNotification>(
                onNotification: _onScroll,
                // InkClip：将行内 InkWell 的 ink（悬停 overlay / 水波纹）裁剪到
                // 列表视口内。否则 ink 由外层 Material 绘制、不受 ListView 视口
                // 裁剪，半露出视口的行其悬停高亮会越界画到列表上下边界之外。
                child: InkClip(
                  child: ListView.builder(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: listCount + 1,
                    // 固定行高虚拟化：每行按 O(index) 定位，免去逐子项测量。
                    // 歌曲行恒为 _songRowExtent；尾项为空列表时 0，否则高度。
                    itemExtentBuilder: (index, _) => index == listCount
                        ? (listCount == 0
                              ? 0.0
                              : _SongListState._songFooterExtent)
                        : _SongListState._songRowExtent,
                    itemBuilder: (context, index) {
                      if (index == listCount) {
                        return _SongListFooter(
                          visible: listCount > 0,
                          loadingMore: widget.loadingMore,
                          hasMore: widget.hasMore,
                        );
                      }
                      final Track? item;
                      if (widget.totalCount != null) {
                        // 窗口模式：全局 index 映射到页缓存；未驻留返回 null。
                        item = widget.itemAt?.call(index);
                      } else {
                        item = widget.items[index];
                      }
                      if (item == null) {
                        // 该行所在页尚未驻留：轻量占位并触发异步取页，
                        // 页到位后 rebuild 用真实行替换（驻留内存 O(视口)）。
                        widget.onMissingIndex?.call(index);
                        return const SizedBox.shrink();
                      }
                      // 提升为非空局部量，供闭包内引用（闭包中不再保留提升）。
                      final Track track = item;
                      return SongRow(
                        item: track,
                        index: index,
                        showIndex: widget.showIndex,
                        showAlbum: widget.showAlbum,
                        showDuration: widget.showDuration,
                        showSource: widget.showSource,
                        isPlaying: widget.playingId == item.id,
                        playingNow: widget.isPlaying,
                        liked:
                            widget.likedIds?.contains(songLikeKey(item)) ??
                            false,
                        onPlay: widget.onPlay,
                        onToggleLike: widget.onToggleLike,
                        onContextMenu: widget.onContextMenu,
                        batchActive: _batchActive,
                        selected: _selected.contains(songLikeKey(item)),
                        onToggleSelect: () => _toggleSelect(track, index),
                      );
                    },
                  ),
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
    required this.allSelected,
    required this.showIndex,
    required this.showAlbum,
    required this.showDuration,
    required this.downloadModule,
    required this.l10n,
    required this.scheme,
    required this.onEnterBatch,
    required this.onSelectAll,
    required this.onClearAll,
    required this.onInvert,
    required this.onBatchPlay,
    required this.onBatchAddQueue,
    required this.onBatchDownload,
    required this.onBatchEditMetadata,
    this.onBatchAddToPlaylist,
    required this.onExitBatch,
  });

  final bool batchActive;
  final List<Track> items;
  final Set<String> selected;
  final int selectedCount;
  final bool allSelected;
  final bool showIndex;
  final bool showAlbum;
  final bool showDuration;
  final bool downloadModule;
  final AppLocalizations l10n;
  final ColorScheme scheme;
  final VoidCallback onEnterBatch;
  final VoidCallback onSelectAll;
  final VoidCallback onClearAll;
  final VoidCallback onInvert;
  final Future<void> Function() onBatchPlay;
  final VoidCallback onBatchAddQueue;
  final Future<void> Function() onBatchDownload;

  /// 批量「编辑元数据」回调（null → 不显示该按钮）。
  final VoidCallback? onBatchEditMetadata;

  /// 批量「添加到歌单」回调（null → 不显示该按钮）。
  final VoidCallback? onBatchAddToPlaylist;
  final VoidCallback onExitBatch;

  @override
  Widget build(BuildContext context) {
    if (batchActive) {
      final all = allSelected;
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
                l10n.queueTrackCount(count: selectedCount),
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
            if (downloadModule)
              _SongListIconButton(
                tooltip: l10n.batchDownload,
                icon: EtaIcons.downloadOutline,
                enabled: !none,
                onTap: () => onBatchDownload(),
              ),
            if (onBatchAddToPlaylist != null)
              _SongListIconButton(
                tooltip: l10n.playlistPickTitle,
                icon: EtaIcons.add,
                enabled: !none,
                onTap: onBatchAddToPlaylist!,
              ),
            if (onBatchEditMetadata != null)
              _SongListIconButton(
                tooltip: l10n.menuBatchEditMetadata,
                icon: EtaIcons.editOutline,
                enabled: !none,
                onTap: onBatchEditMetadata!,
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
      height: _SongListState._songFooterExtent,
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
