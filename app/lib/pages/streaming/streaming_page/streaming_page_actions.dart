// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../streaming_page.dart';

extension _StreamingPageActions on _StreamingPageState {
  void _onTabChanged() {
    if (_tab.indexIsChanging) return;
    _fetchCurrent();
  }

  void _fetchCurrent() {
    final n = ref.read(streamingProvider.notifier);
    switch (_tab.index) {
      case 0:
        n.fetchSongs();
      case 1:
        n.fetchAlbums();
      case 2:
        n.fetchArtists();
      default:
        n.fetchPlaylists();
    }
  }

  void _refreshCurrent() {
    final n = ref.read(streamingProvider.notifier);
    switch (_tab.index) {
      case 0:
        n.refresh(tab: 'songs');
      case 1:
        n.refresh(tab: 'albums');
      case 2:
        n.refresh(tab: 'artists');
      default:
        n.refresh(tab: 'playlists');
    }
  }

  void _openStreamingSettings() {
    showSettingsDialog(context, category: SettingsCategory.mediaSource);
  }

  void _connectStreaming() {
    ref.read(streamingProvider.notifier).connect();
  }
}
