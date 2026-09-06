// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../artist_detail_page.dart';

extension _StreamingArtistDetailPageView on _StreamingArtistDetailPageState {
  Widget _buildArtistDetailPage(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final playback = ref.watch(
      playbackProvider.select((s) => (trackId: s.trackId, playing: s.playing)),
    );
    final artists = ref.watch(streamingProvider.select((s) => s.artists));
    final meta = artists.where((a) => a.id == widget.id).firstOrNull;
    final albums = _albums;
    final songs = _songs;
    final notifier = ref.read(playbackProvider.notifier);

    return DetailScaffold(
      header: DetailHeader(
        cover: meta?.avatar,
        circle: true,
        title: meta?.name ?? '',
        subtitle: albums != null
            ? l10n.streamingArtistAlbums(albums.length)
            : '',
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
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (albums != null && albums.isNotEmpty) ...[
                DetailSectionTitle(title: l10n.streamingTabsAlbums),
                CoverGrid(
                  items: [
                    for (final a in albums)
                      CoverItem(
                        id: a.id,
                        title: a.name,
                        cover: a.cover,
                        subtitle: a.artist ?? '',
                        trackCount: a.trackCount ?? 0,
                      ),
                  ],
                  onTap: _openAlbumDetail,
                ),
              ],
              if (songs != null && songs.isNotEmpty) ...[
                DetailSectionTitle(title: l10n.streamingTabsSongs),
                SongList(
                  items: songs,
                  playingId: playback.trackId,
                  isPlaying: playback.playing,
                  showAlbum: true,
                  onPlay: (t) => _playSongFromList(songs, t),
                  onContextMenu: (t, pos) => _showSongMenu(songs, t, pos),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
