// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../streaming_provider.dart';

mixin _StreamingNotifierCore on Notifier<StreamingState> {
  bool get _songsLoaded;
  set _songsLoaded(bool value);

  bool get _albumsLoaded;
  set _albumsLoaded(bool value);

  bool get _artistsLoaded;
  set _artistsLoaded(bool value);

  bool get _playlistsLoaded;
  set _playlistsLoaded(bool value);

  void _persist() {
    final s = state;
    StreamingStore.save(s.servers, s.activeServerId);
  }

  void _resetBrowseCache() {
    _songsLoaded = false;
    _albumsLoaded = false;
    _artistsLoaded = false;
    _playlistsLoaded = false;
    state = state.copyWith(
      songs: const [],
      albums: const [],
      artists: const [],
      playlists: const [],
    );
  }

  StreamingClient? get _client {
    final cfg = state.activeServer;
    if (cfg == null || !state.connected) return null;
    return StreamingClient(cfg);
  }

  void _setLoading(bool value) => state = state.copyWith(loading: value);
}
