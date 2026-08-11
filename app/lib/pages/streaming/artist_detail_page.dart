import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../services/netease/netease_api.dart';
import '../../services/netease/track.dart';
import '../../services/playback/playback_notifier.dart';
import '../../services/streaming/streaming_client.dart';
import '../../services/streaming/streaming_models.dart';
import '../../services/streaming/streaming_provider.dart';
import '../../l10n/l10n.dart';
import '../../widgets/dialogs/track_context_menu.dart';
import '../../widgets/list/cover_grid.dart';
import '../../widgets/list/song_list.dart';
import 'detail_scaffold.dart';

/// 流媒体歌手详情页：专辑网格 + 全部歌曲。
class StreamingArtistDetailPage extends ConsumerStatefulWidget {
  const StreamingArtistDetailPage({super.key, required this.id});

  final String id;

  @override
  ConsumerState<StreamingArtistDetailPage> createState() =>
      _StreamingArtistDetailPageState();
}

class _StreamingArtistDetailPageState
    extends ConsumerState<StreamingArtistDetailPage> {
  List<StreamingAlbum>? _albums;
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
      final client = StreamingClient(cfg);
      final results = await Future.wait([
        client.getArtistAlbums(widget.id),
        client.getArtistSongs(widget.id),
      ]);
      if (!mounted) return;
      setState(() {
        _albums = results[0] as List<StreamingAlbum>;
        _songs = results[1] as List<Track>;
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
                  onTap: (item) => context.push(
                    '/streaming/album/${Uri.encodeComponent(item.id)}',
                  ),
                ),
              ],
              if (songs != null && songs.isNotEmpty) ...[
                DetailSectionTitle(title: l10n.streamingTabsSongs),
                SongList(
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
              ],
            ],
          ),
        ),
      ),
    );
  }
}
