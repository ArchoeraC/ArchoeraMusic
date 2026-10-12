// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/playback/playback_notifier.dart';
import '../../services/streaming/streaming_client.dart';
import '../../services/streaming/streaming_models.dart';
import '../../services/streaming/streaming_provider.dart';

/// 播放整张专辑（进入专辑页拉取后播放）。
Future<void> playStreamingAlbum(WidgetRef ref, StreamingAlbum album) async {
  final id = ref.read(streamingProvider).activeServerId;
  if (id == null) return;
  try {
    final cfg = await ref.read(streamingProvider.notifier).resolvedServer(id);
    if (cfg == null) return;
    final songs = await StreamingClient(cfg).getAlbumSongs(album.id);
    if (songs.isEmpty) return;
    ref.read(playbackProvider.notifier).playQueue(songs);
  } catch (_) {
    // 失败静默（详情页可完整播放）
  }
}

/// 播放整个歌单。
Future<void> playStreamingPlaylist(
  WidgetRef ref,
  StreamingPlaylist playlist,
) async {
  final id = ref.read(streamingProvider).activeServerId;
  if (id == null) return;
  try {
    final cfg = await ref.read(streamingProvider.notifier).resolvedServer(id);
    if (cfg == null) return;
    final songs = await StreamingClient(cfg).getPlaylistSongs(playlist.id);
    if (songs.isEmpty) return;
    ref.read(playbackProvider.notifier).playQueue(songs);
  } catch (_) {
    // 失败静默
  }
}
