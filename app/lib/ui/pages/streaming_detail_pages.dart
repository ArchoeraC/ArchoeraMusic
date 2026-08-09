/// 流媒体详情页（专辑 / 歌手 / 歌单）。
///
/// 子路由挂在 /streaming 分支下：album/:id / artist/:id / playlist/:id。
/// 数据经 [StreamingClient] 拉取，头部展示元信息 + 播放全部，主体复用
/// [SongList] / [CoverGrid]。服务器配置取当前激活服务器。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/netease/netease_api.dart';
import '../../core/netease/track.dart';
import '../../core/playback/playback_notifier.dart';
import '../../core/streaming/streaming_client.dart';
import '../../core/streaming/streaming_models.dart';
import '../../core/streaming/streaming_provider.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import '../widgets/cover_grid.dart';
import '../widgets/cover_image.dart';
import '../widgets/s_controls.dart';
import '../widgets/song_list.dart';
import '../widgets/track_context_menu.dart';

/// 专辑详情页。
class StreamingAlbumDetailPage extends ConsumerStatefulWidget {
  const StreamingAlbumDetailPage({super.key, required this.id});

  final String id;

  @override
  ConsumerState<StreamingAlbumDetailPage> createState() =>
      _StreamingAlbumDetailPageState();
}

class _StreamingAlbumDetailPageState
    extends ConsumerState<StreamingAlbumDetailPage> {
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
      final songs = await StreamingClient(cfg).getAlbumSongs(widget.id);
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
    final playback = ref.watch(playbackProvider);
    final albums = ref.watch(streamingProvider.select((s) => s.albums));
    final meta = albums.where((a) => a.id == widget.id).firstOrNull;
    final songs = _songs;
    final notifier = ref.read(playbackProvider.notifier);

    return _DetailScaffold(
      header: _DetailHeader(
        cover: meta?.cover,
        title: meta?.name ?? '',
        subtitle: [
          if (meta?.artist?.isNotEmpty == true) meta!.artist!,
          if (songs != null)
            l10n.streamingAlbumSongs(songs.length),
        ].join(' · '),
        onPlayAll: songs == null || songs.isEmpty
            ? null
            : () => notifier.playQueue(songs),
      ),
      body: _DetailBody(
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

/// 歌手详情页：专辑网格 + 全部歌曲。
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
    final playback = ref.watch(playbackProvider);
    final artists = ref.watch(streamingProvider.select((s) => s.artists));
    final meta = artists.where((a) => a.id == widget.id).firstOrNull;
    final albums = _albums;
    final songs = _songs;
    final notifier = ref.read(playbackProvider.notifier);

    return _DetailScaffold(
      header: _DetailHeader(
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
      body: _DetailBody(
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
                _SectionTitle(title: l10n.streamingTabsAlbums),
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
                _SectionTitle(title: l10n.streamingTabsSongs),
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

/// 歌单详情页。
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
    final playback = ref.watch(playbackProvider);
    final playlists = ref.watch(streamingProvider.select((s) => s.playlists));
    final meta = playlists.where((p) => p.id == widget.id).firstOrNull;
    final songs = _songs;
    final notifier = ref.read(playbackProvider.notifier);

    return _DetailScaffold(
      header: _DetailHeader(
        cover: meta?.cover,
        title: meta?.name ?? '',
        subtitle: [
          if (meta?.owner?.isNotEmpty == true) meta!.owner!,
          if (songs != null)
            l10n.streamingPlaylistSongs(songs.length),
        ].join(' · '),
        onPlayAll: songs == null || songs.isEmpty
            ? null
            : () => notifier.playQueue(songs),
      ),
      body: _DetailBody(
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

/// 详情页骨架：返回栏 + 头部 + 内容。
class _DetailScaffold extends StatelessWidget {
  const _DetailScaffold({required this.header, required this.body});

  final Widget header;
  final Widget body;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 返回栏
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: IconButton(
              tooltip: context.l10n.commonBack,
              iconSize: 20,
              visualDensity: VisualDensity.compact,
              onPressed: () => context.pop(),
              icon: Icon(Icons.arrow_back, color: scheme.onSurface),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
          child: header,
        ),
        const Divider(height: 1),
        Expanded(child: body),
      ],
    );
  }
}

/// 详情头部：封面 + 标题 + 副标题 + 播放全部。
class _DetailHeader extends StatelessWidget {
  const _DetailHeader({
    required this.title,
    this.cover,
    this.circle = false,
    this.subtitle = '',
    this.onPlayAll,
  });

  final String? cover;
  final bool circle;
  final String title;
  final String subtitle;
  final VoidCallback? onPlayAll;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (circle)
          ClipOval(
            child: CoverImage(cover: cover, width: 108, height: 108, radius: 54),
          )
        else
          CoverImage(cover: cover, width: 108, height: 108, radius: 12),
        const SizedBox(width: 18),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title.isEmpty ? l10n.commonUnknownAlbum : title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurface,
                  height: 1.3,
                ),
              ),
              if (subtitle.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                    height: 1.4,
                  ),
                ),
              ],
              if (onPlayAll != null) ...[
                const SizedBox(height: 12),
                SButton(
                  label: l10n.commonPlayAll,
                  icon: Icons.play_arrow,
                  variant: SButtonVariant.primary,
                  size: SButtonSize.small,
                  onPressed: onPlayAll,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// 详情内容状态：加载 / 错误 / 子内容。
class _DetailBody extends StatelessWidget {
  const _DetailBody({
    required this.loading,
    required this.error,
    required this.l10n,
    required this.scheme,
    required this.onRetry,
    required this.child,
  });

  final bool loading;
  final String? error;
  final AppLocalizations l10n;
  final ColorScheme scheme;
  final VoidCallback onRetry;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              size: 36,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 10),
            Text(
              error == 'no-server' ? l10n.streamingEmptyNotConnected : '$error',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 12),
            SButton(
              label: l10n.commonRetry,
              icon: Icons.refresh,
              variant: SButtonVariant.secondary,
              size: SButtonSize.small,
              onPressed: onRetry,
            ),
          ],
        ),
      );
    }
    return child;
  }
}

/// 区块标题（歌手页：专辑 / 歌曲）。
class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
        ),
      ),
    );
  }
}
