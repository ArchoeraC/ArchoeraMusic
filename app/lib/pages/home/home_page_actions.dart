// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// ignore_for_file: invalid_use_of_protected_member

part of '../home_page.dart';

extension _HomePageActions on _HomePageState {
  Future<void> _fetchAll() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final api = ref.read(neteaseApiProvider);
      final results = await Future.wait<Object>([
        api.personalized(limit: 16),
        api.newAlbums(limit: 16),
        api.topArtists(limit: 16),
      ]);
      if (!mounted) return;
      setState(() {
        _data = _HomeData(
          playlists: results[0] as List<CoverItem>,
          albums: results[1] as List<CoverItem>,
          artists: results[2] as List<CoverItem>,
        );
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _toast(String msg) => toast(msg);

  void _openDaily() {
    final l10n = context.l10n;
    final account = ref.read(neteaseAuthProvider);
    if (account == null) {
      _toast(l10n.toastDailyRequiresLogin(l10n.platformNetease));
      showNeteaseLoginDialog(context);
      return;
    }
    showDailyRecommendDialog(context);
  }

  void _openPlaylist(CoverItem playlist) {
    showPlaylistDetailDialog(context, playlist);
  }

  void _openAlbum(CoverItem album) {
    showNeteaseAlbumDialog(context, album);
  }

  void _openArtist(CoverItem artist) {
    showNeteaseArtistDialog(context, artist);
  }

  Future<void> _playAllPlaylist(CoverItem playlist) async {
    final l10n = context.l10n;
    try {
      final detail = await ref
          .read(neteaseApiProvider)
          .playlistDetail(playlist.id);
      final tracks = detail.tracks;
      if (tracks.isEmpty) {
        _toast(l10n.toastPlaylistEmpty);
        return;
      }
      ref.read(playbackProvider.notifier).playQueue(tracks);
      _toast(l10n.toastPlayedAll(tracks.length));
    } catch (e) {
      _toast(l10n.toastPlayFailed('$e'));
    }
  }

  Future<void> _playAllAlbum(CoverItem album) async {
    final l10n = context.l10n;
    try {
      final tracks = await ref.read(neteaseApiProvider).albumTracks(album.id);
      if (tracks.isEmpty) {
        _toast(l10n.toastAlbumEmpty);
        return;
      }
      ref.read(playbackProvider.notifier).playQueue(tracks);
      _toast(l10n.toastPlayedAll(tracks.length));
    } catch (e) {
      _toast(l10n.toastPlayFailed('$e'));
    }
  }

  void _openRank() {
    final l10n = context.l10n;
    showKugouBrowseDialog(
      context,
      title: l10n.pageHomeRankTitle,
      loader: (ref) => ref.read(kugouApiProvider).rankList(),
      onItemTap: (ctx, rank) => showKugouRankDialog(ctx, rank),
    );
  }

  void _openPlaylistSquare() {
    final l10n = context.l10n;
    showKugouBrowseDialog(
      context,
      title: l10n.pageHomePlaylistSquare,
      loader: (ref) => ref.read(kugouApiProvider).topPlaylists(),
      onItemTap: (ctx, playlist) =>
          showKugouPlaylistDetailDialog(ctx, playlist),
    );
  }

  void _openMoreArtists() {
    final l10n = context.l10n;
    showKugouBrowseDialog(
      context,
      title: l10n.pageHomeHotArtists,
      loader: (ref) => ref.read(neteaseApiProvider).topArtists(limit: 50),
      onItemTap: (ctx, artist) => showNeteaseArtistDialog(ctx, artist),
      artist: true,
    );
  }

  void _openMorePlaylists() {
    final l10n = context.l10n;
    showKugouBrowseDialog(
      context,
      title: l10n.pageHomePlaylists,
      loader: (ref) => ref.read(neteaseApiProvider).personalized(limit: 50),
      onItemTap: (ctx, playlist) => showPlaylistDetailDialog(ctx, playlist),
    );
  }

  void _openMoreAlbums() {
    final l10n = context.l10n;
    showKugouBrowseDialog(
      context,
      title: l10n.pageHomeNewAlbums,
      loader: (ref) => ref.read(neteaseApiProvider).newAlbums(limit: 50),
      onItemTap: (ctx, album) => showNeteaseAlbumDialog(ctx, album),
    );
  }

  String _greetingText(AppLocalizations l10n) {
    final hour = DateTime.now().hour;
    if (hour < 5) return l10n.greetingLate;
    if (hour < 12) return l10n.greetingMorning;
    if (hour < 18) return l10n.greetingAfternoon;
    return l10n.greetingEvening;
  }
}
