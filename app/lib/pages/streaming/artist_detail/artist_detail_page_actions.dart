// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../artist_detail_page.dart';

extension _StreamingArtistDetailPageActions on _StreamingArtistDetailPageState {
  Future<void> _load() async {
    _startLoading();
    final cfg = ref.read(streamingProvider).activeServer;
    if (cfg == null) {
      _setLoadError('no-server');
      return;
    }
    try {
      final client = StreamingClient(cfg);
      final results = await Future.wait([
        client.getArtistAlbums(widget.id),
        client.getArtistSongs(widget.id),
      ]);
      if (!mounted) return;
      _setLoadedData(
        results[0] as List<StreamingAlbum>,
        results[1] as List<Track>,
      );
    } catch (e) {
      if (!mounted) return;
      _setLoadError('$e');
    }
  }

  void _openAlbumDetail(CoverItem item) {
    context.push('/streaming/album/${Uri.encodeComponent(item.id)}');
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
