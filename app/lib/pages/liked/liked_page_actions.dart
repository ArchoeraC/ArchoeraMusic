// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// ignore_for_file: invalid_use_of_protected_member

part of '../liked_page.dart';

extension _LikedPageActions on _LikedPageState {
  void _ensureLoaded(String platform) {
    if (platform == _LikedPageState._qqPlatform) {
      _qqStore.ensureLoaded();
      if (kQqFavExperimental && ref.read(qqMusicApiProvider).isLoggedIn) {
        unawaited(_mergeQqOnlineQuiet());
      }
    } else {
      _store.ensureLoaded(platform);
    }
  }

  Future<void> _mergeQqOnlineQuiet() async {
    try {
      final online = await ref.read(qqMusicApiProvider).likedSongs();
      await _qqStore.mergeOnline(online);
      ref.read(likeControllerProvider).mergeOnlineQq(online);
    } catch (_) {
      // 静默（页内右上角「同步在线收藏」按钮提供显式重试与提示）
    }
  }

  void _switchPlatform(String platform) {
    if (platform == _platform) return;
    setState(() => _platform = platform);
    if (_loggedIn) _ensureLoaded(platform);
  }

  void _onAuthChanged(String platform) {
    if (platform == _LikedPageState._qqPlatform) {
      setState(() {});
      return;
    }
    final store = _store;
    store.reset(platform);
    final logged = platform == 'kugou' ? _kugouLoggedIn : _neteaseLoggedIn;
    if (logged) store.ensureLoaded(platform);
  }

  void _toast(String msg) => toast(msg);

  Future<void> _playAll() async {
    if (_resolving) return;
    setState(() => _resolving = true);
    try {
      final tracks = _tracks(_platform);
      if (tracks.isEmpty) return;
      await ref.read(playbackProvider.notifier).playQueue(tracks);
      if (!mounted) return;
      _toast(context.l10n.toastPlayedAll(tracks.length));
    } catch (e) {
      if (mounted) _toast(context.l10n.trackListPlaySourceFailed('$e'));
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  Future<void> _playTrack(Track track) async {
    if (_resolving) return;
    setState(() => _resolving = true);
    try {
      final String? url;
      if (track.source == 'kugou' && track.kugou != null) {
        url = await ref.read(kugouApiProvider).resolvePlayUrl(track.kugou!);
      } else if (track.source == 'netease') {
        url = await ref.read(neteaseApiProvider).resolvePlayUrl(track.id);
      } else if (track.source == 'qqmusic') {
        url = await ref.read(qqMusicApiProvider).resolvePlayUrl(track);
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
      if (mounted) setState(() => _resolving = false);
    }
  }

  String _likeFailText(String source) {
    final l10n = context.l10n;
    return switch (source) {
      'kugou' => l10n.toastLoginRequiredKugou,
      'qqmusic' => l10n.toastQqLikeSyncFailed,
      _ => l10n.toastLoginRequiredNetease,
    };
  }

  Future<void> _toggleLike(Track track) async {
    final controller = ref.read(likeControllerProvider);
    final ok = await controller.toggle(track);
    if (!mounted) return;
    if (!ok) {
      _toast(_likeFailText(track.source));
      return;
    }
  }

  void _onTrackMenu(Track track, Offset global) {
    showTrackContextMenu(
      context,
      ref: ref,
      track: track,
      position: global,
      onPlay: () => _playTrack(track),
      onToggleLike: (t) async {
        final ok = await ref.read(likeControllerProvider).toggle(t);
        if (!mounted) return;
        if (!ok) {
          _toast(_likeFailText(t.source));
        }
      },
    );
  }

  Future<void> _refreshQqOnline() async {
    final l10n = context.l10n;
    if (!kQqFavExperimental) {
      _toast(l10n.toastQqLikeSyncFailed);
      return;
    }
    if (!_qqLoggedIn) {
      final ok = await showQqMusicLoginDialog(context);
      if (ok != true || !mounted) return;
    }
    try {
      final online = await ref.read(qqMusicApiProvider).likedSongs();
      final n = await _qqStore.mergeOnline(online);
      ref.read(likeControllerProvider).mergeOnlineQq(online);
      if (!mounted) return;
      _toast(n > 0 ? l10n.pageLikedQqSynced(n) : l10n.pageLikedQqSyncedNone);
    } catch (_) {
      if (!mounted) return;
      _toast(l10n.toastQqLikeSyncFailed);
    }
  }

  void _showQqLogin() {
    showQqMusicLoginDialog(context);
  }
}
