import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/playback/playback_notifier.dart';
import '../../services/streaming/streaming_client.dart';
import '../../services/streaming/streaming_models.dart';
import '../../services/streaming/streaming_provider.dart';

/// 播放整张专辑（进入专辑页拉取后播放）。
Future<void> playStreamingAlbum(WidgetRef ref, StreamingAlbum album) async {
  final cfg = ref.read(streamingProvider).activeServer;
  if (cfg == null) return;
  try {
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
  final cfg = ref.read(streamingProvider).activeServer;
  if (cfg == null) return;
  try {
    final songs = await StreamingClient(cfg).getPlaylistSongs(playlist.id);
    if (songs.isEmpty) return;
    ref.read(playbackProvider.notifier).playQueue(songs);
  } catch (_) {
    // 失败静默
  }
}
