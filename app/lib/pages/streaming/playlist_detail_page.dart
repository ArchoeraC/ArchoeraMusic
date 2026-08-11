import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/netease/track.dart';
import '../../services/playback/playback_notifier.dart';
import '../../services/streaming/streaming_client.dart';
import '../../services/streaming/streaming_provider.dart';
import '../../l10n/l10n.dart';
import '../../widgets/dialogs/track_context_menu.dart';
import '../../widgets/list/song_list.dart';
import 'detail_scaffold.dart';

/// 流媒体歌单详情页。
class StreamingPlaylistDetailPage extends ConsumerStatefulWidget {
  const StreamingPlaylistDetailPage({super.key, required this.id});

  final String id;

  @override
  ConsumerState<StreamingPlaylistDetailPage> createState() =>
      _StreamingPlaylistDetailPageState();
}

class _StreamingPlaylistDetailPageState
    extends ConsumerState<StreamingPlaylistDetailPage> {
  List<Track>? _songs;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final cfg = ref.read(streamingProvider).activeServer;
    if (cfg == null) {
      setState(() {
        _loading = false;
        _error = 'no-server';
      });
      return;
    }
    try {
      final songs = await StreamingClient(cfg).getPlaylistSongs(widget.id);
      if (!mounted) return;
      setState(() {
        _songs = songs;
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

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final playback = ref.watch(
      playbackProvider.select((s) => (trackId: s.trackId, playing: s.playing)),
    );
    final playlists = ref.watch(streamingProvider.select((s) => s.playlists));
    final meta = playlists.where((p) => p.id == widget.id).firstOrNull;
    final songs = _songs;
    final notifier = ref.read(playbackProvider.notifier);

    return DetailScaffold(
      header: DetailHeader(
        cover: meta?.cover,
        title: meta?.name ?? '',
        subtitle: [
          if (meta?.owner?.isNotEmpty == true) meta!.owner!,
          if (songs != null) l10n.streamingPlaylistSongs(songs.length),
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
                onPlay: (t) {
                  final idx = songs.indexWhere((x) => x.id == t.id);
                  notifier.playQueue(songs, startIndex: idx < 0 ? 0 : idx);
                },
                onContextMenu: (t, pos) => showTrackContextMenu(
                  context,
                  ref: ref,
                  track: t,
                  position: pos,
                  onPlay: () {
                    final idx = songs.indexWhere((x) => x.id == t.id);
                    notifier.playQueue(songs, startIndex: idx < 0 ? 0 : idx);
                  },
                ),
              ),
      ),
    );
  }
}
