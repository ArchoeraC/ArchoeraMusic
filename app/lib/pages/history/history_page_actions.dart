// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../history_page.dart';

extension _HistoryPageActions on _HistoryPageState {
  /// 变更事件 → 下一微任务合并重载（异步投递，不阻塞写入方调用链）。
  void _scheduleReload() {
    if (_reloadScheduled) return;
    _setReloadScheduled(true);
    Future.microtask(() {
      _setReloadScheduled(false);
      _load();
    });
  }

  void _load() {
    final entries = ref.read(historyStoreProvider).entries();
    if (!mounted) return;
    _applyLoadedEntries(entries);
  }

  /// 播放全部（对齐 History.vue handlePlayAll：playFrom(tracks, 0)）。
  void _playAll() {
    final tracks = _tracks;
    if (tracks.isEmpty) return;
    ref.read(playbackProvider.notifier).playQueue(tracks);
  }

  Future<void> _playTrack(Track track) async {
    if (_resolving) return;
    _setResolving(true);
    try {
      final String? url;
      if (track.source == 'kugou' && track.kugou != null) {
        url = await ref.read(kugouApiProvider).resolvePlayUrl(track.kugou!);
      } else if (track.source == 'local') {
        url = track.localPath;
      } else if (track.source == 'netease') {
        url = await ref.read(neteaseApiProvider).resolvePlayUrl(track.id);
      } else {
        url = null;
      }
      if (!mounted) return;
      if (url == null || url.isEmpty) {
        _toast(context.l10n.trackListNoPlayableSource);
        return;
      }
      await ref
          .read(playbackProvider.notifier)
          .playNow(track, resolvedUrl: url);
    } catch (e) {
      if (mounted) _toast(context.l10n.trackListPlaySourceFailed('$e'));
    } finally {
      if (mounted) _setResolving(false);
    }
  }

  /// 单条移除（右键菜单）。列表刷新由 [HistoryStore.changes] 事件驱动。
  void _removeEntry(Track track) {
    ref.read(historyStoreProvider).remove(track);
    _toast(context.l10n.pageHistoryRemoved);
  }

  /// 清空全部（确认弹窗）。
  Future<void> _confirmClear() async {
    final l10n = context.l10n;
    final ok = await SDialog.show<bool>(
      context,
      title: l10n.pageHistoryClearTitle,
      description: l10n.pageHistoryClearMessage,
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
          onPressed: () => Navigator.pop(context, true),
          child: Text(l10n.commonClear),
        ),
      ],
      child: const SizedBox.shrink(),
    );
    if (ok != true) return;
    ref.read(historyStoreProvider).clear();
    _toast(l10n.pageHistoryCleared);
  }

  /// 行右键菜单（通用在线曲目菜单 + 页内「从历史移除」）。
  void _onRowMenu(Track track, Offset global) {
    showTrackContextMenu(
      context,
      ref: ref,
      track: track,
      position: global,
      onPlay: () => _playTrack(track),
      extra: [
        SContextMenuItem(
          label: context.l10n.pageHistoryRemove,
          icon: EtaIcons.deleteOutline,
          onTap: () => _removeEntry(track),
        ),
      ],
    );
  }
}
