// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../playlist_detail_page.dart';

extension _StreamingPlaylistDetailPageActions
    on _StreamingPlaylistDetailPageState {
  Future<void> _load() async {
    _startLoading();
    final id = ref.read(streamingProvider).activeServerId;
    // 凭据按需解密：解析带凭据配置并发起请求（不读状态明文）。
    final cfg = id == null
        ? null
        : await ref.read(streamingProvider.notifier).resolvedServer(id);
    if (cfg == null) {
      _setLoadError('no-server');
      return;
    }
    try {
      final songs = await StreamingClient(cfg).getPlaylistSongs(widget.id);
      if (!mounted) return;
      _setSongsLoaded(songs);
    } catch (e) {
      if (!mounted) return;
      _setLoadError('$e');
    }
  }

  void _playSongFromList(List<Track> songs, Track track) {
    final idx = songs.indexWhere((x) => x.id == track.id);
    ref
        .read(playbackProvider.notifier)
        .playQueue(songs, startIndex: idx < 0 ? 0 : idx);
  }

  void _showSongMenu(List<Track> songs, Track track, Offset position) {
    showTrackContextMenu(
      context,
      ref: ref,
      track: track,
      position: position,
      onPlay: () => _playSongFromList(songs, track),
    );
  }
}
