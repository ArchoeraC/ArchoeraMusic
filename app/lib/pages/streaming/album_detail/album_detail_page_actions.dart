// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../album_detail_page.dart';

extension _StreamingAlbumDetailPageActions on _StreamingAlbumDetailPageState {
  Future<void> _load() async {
    _startLoading();
    final cfg = ref.read(streamingProvider).activeServer;
    if (cfg == null) {
      _setLoadError('no-server');
      return;
    }
    try {
      final songs = await StreamingClient(cfg).getAlbumSongs(widget.id);
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
