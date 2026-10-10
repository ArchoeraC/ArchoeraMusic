// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// ignore_for_file: invalid_use_of_protected_member

part of '../track_list_dialog.dart';

extension _TrackListDialogActions on _TrackListDialogState {
  Future<void> _playTrack(Track track) async {
    if (_resolving) return;
    setState(() => _resolving = true);
    try {
      final String? url = await sourcePlatform(track.source)
          .resolvePlayUrl(ref, track, quality: 'hq');
      if (!mounted) return;
      if (url == null || url.isEmpty) {
        _toast(context.l10n.trackListNoPlayableSource);
        return;
      }
      await ref
          .read(playbackProvider.notifier)
          .playNow(track, resolvedUrl: url);
    } catch (e) {
      if (mounted) _toast(context.l10n.trackListPlaySourceFailed(msg: '$e'));
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  Future<void> _playAll(List<Track> tracks) async {
    if (tracks.isEmpty) return;
    try {
      await ref.read(playbackProvider.notifier).playQueue(tracks);
    } catch (_) {
      // 错误已记入播放日志
    }
  }

  /// 刷新：先执行调用方的刷新回调（如强制刷新日推），再重新加载列表。
  Future<void> _refresh() async {
    final fn = widget.onRefresh;
    if (fn == null || _refreshing) return;
    setState(() => _refreshing = true);
    try {
      await fn(ref);
    } catch (_) {
      // 刷新失败仍回读缓存列表
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
    if (mounted) await _reload();
  }

  void _onTrackMenu(Track track, Offset global) {
    final listId = widget.playlistId;
    final canRemove =
        listId != null &&
        track.source == widget.playlistSource &&
        readUserPlaylists(ref, widget.playlistSource).isOwned(listId);
    showTrackContextMenu(
      context,
      ref: ref,
      track: track,
      position: global,
      onPlay: () => _playTrack(track),
      extra: canRemove
          ? [
              SContextMenuItem(
                label: context.l10n.playlistRemoveTrack,
                icon: EtaIcons.deleteOutline,
                danger: true,
                onTap: () => _removeFromPlaylist(listId, track),
              ),
            ]
          : const [],
    );
  }

  /// 批量添加到歌单（选择器；排除当前歌单自身）。
  Future<void> _batchAddToPlaylist(List<Track> tracks) =>
      showPlaylistPickerDialog(
        context,
        source: widget.playlistSource,
        tracks: tracks,
        excludeId: widget.playlistId,
      );

  /// 从当前自建歌单移除该曲目并重载列表。
  Future<void> _removeFromPlaylist(String playlistId, Track track) async {
    final ops = userPlaylistsOps(ref, widget.playlistSource);
    if (ops == null) return;
    try {
      await ops.removeTracks(playlistId, [track.id]);
      if (!mounted) return;
      toast(context.l10n.playlistRemoveDone);
      await _reload();
    } catch (_) {
      if (mounted) toast(context.l10n.playlistRemoveFailed);
    }
  }
}
