// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// ignore_for_file: invalid_use_of_protected_member

part of '../liked_page.dart';

extension _LikedPageActions on _LikedPageState {
  void _switchPlatform(String platform) {
    if (platform == _platform) return;
    ref.read(likedPlatformProvider.notifier).set(platform);
    setState(() => _platform = platform);
    final adapter = collectionPlatform(platform);
    if (adapter.likedAvailable(ref)) adapter.ensureLikedLoaded(ref);
  }

  /// 登录态变化：重置该平台并（可用时）重新加载。QQ 本机库无需重置。
  void _onAuthChanged(String platform) {
    final adapter = collectionPlatform(platform);
    if (adapter.localLikedStore) {
      setState(() {});
      return;
    }
    adapter.resetLiked(ref);
    if (adapter.likedAvailable(ref)) adapter.ensureLikedLoaded(ref);
  }

  void _toast(String msg) => toast(msg);

  Future<void> _playAll() async {
    if (_resolving) return;
    setState(() => _resolving = true);
    try {
      final tracks = collectionPlatform(_platform).likedView(ref).tracks;
      if (tracks.isEmpty) return;
      await ref.read(playbackProvider.notifier).playQueue(tracks);
      if (!mounted) return;
      _toast(context.l10n.toastPlayedAll(count: tracks.length));
    } catch (e) {
      if (mounted) _toast(context.l10n.trackListPlaySourceFailed(msg: '$e'));
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  Future<void> _playTrack(Track track) async {
    if (_resolving) return;
    setState(() => _resolving = true);
    try {
      final String? url = await sourcePlatform(
        track.source,
      ).resolvePlayUrl(ref, track, quality: 'hq');
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

  Future<void> _toggleLike(Track track) async {
    final ok = await ref.read(likeControllerProvider).toggle(track);
    if (!mounted || ok) return;
    _toast(collectionPlatform(track.source).likeFailedText(context.l10n));
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
        if (!mounted || ok) return;
        _toast(collectionPlatform(t.source).likeFailedText(context.l10n));
      },
    );
  }
}
