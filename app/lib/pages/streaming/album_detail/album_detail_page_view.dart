// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../album_detail_page.dart';

extension _StreamingAlbumDetailPageView on _StreamingAlbumDetailPageState {
  Widget _buildAlbumDetailPage(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final playback = ref.watch(
      playbackProvider.select((s) => (trackId: s.trackId, playing: s.playing)),
    );
    final albums = ref.watch(streamingProvider.select((s) => s.albums));
    final meta = albums.where((a) => a.id == widget.id).firstOrNull;
    final songs = _songs;
    final notifier = ref.read(playbackProvider.notifier);

    return DetailScaffold(
      header: DetailHeader(
        cover: meta?.cover,
        title: meta?.name ?? '',
        subtitle: [
          if (meta?.artist?.isNotEmpty == true) meta!.artist!,
          if (songs != null) l10n.streamingAlbumSongs(songs.length),
        ].join(' · '),
        onPlayAll: songs == null || songs.isEmpty
            ? null
            : () => notifier.playQueue(songs),
      ),
      body: DetailBody(
        loading: _loading,
        error: _error,
        l10n: l10n,
        scheme: scheme,
        onRetry: _load,
        child: songs == null
            ? const SizedBox.shrink()
            : SongList(
                items: songs,
                playingId: playback.trackId,
                isPlaying: playback.playing,
                showAlbum: true,
                onPlay: (t) => _playSongFromList(songs, t),
                onContextMenu: (t, pos) => _showSongMenu(songs, t, pos),
              ),
      ),
    );
  }
}
