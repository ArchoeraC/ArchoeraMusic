// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// ignore_for_file: invalid_use_of_protected_member

part of '../track_list_dialog.dart';

extension _TrackListDialogActions on _TrackListDialogState {
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

  Future<void> _playAll(List<Track> tracks) async {
    if (tracks.isEmpty) return;
    try {
      await ref.read(playbackProvider.notifier).playQueue(tracks);
    } catch (_) {
      // 错误已记入播放日志
    }
  }

  void _onTrackMenu(Track track, Offset global) {
    showTrackContextMenu(
      context,
      ref: ref,
      track: track,
      position: global,
      onPlay: () => _playTrack(track),
    );
  }
}
