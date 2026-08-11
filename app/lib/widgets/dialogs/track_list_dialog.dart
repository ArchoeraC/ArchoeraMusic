import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/netease/netease_api.dart';
import '../../services/netease/track.dart';
import '../../services/playback/playback_notifier.dart';
import '../../stores/providers.dart';
import '../../l10n/l10n.dart';
import '../common/glass_surface.dart';
import '../player/s_controls.dart';
import '../list/song_list.dart';
import '../list/cover_grid.dart';
import '../common/toast.dart';
import 'track_context_menu.dart';

/// 通用酷狗曲目列表弹窗（歌单 / 专辑 / 歌手单曲 / 榜单复用）。
Future<void> showKugouTracksDialog(
  BuildContext context, {
  required String title,
  String? subtitle,
  String? cover,
  required Future<List<Track>> Function(WidgetRef ref) loadTracks,
}) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.5),
    barrierDismissible: true,
    builder: (_) => TrackListDialog(
      title: title,
      subtitle: subtitle,
      cover: cover,
      loadTracks: loadTracks,
    ),
  );
}

/// 酷狗歌单详情弹窗（公开歌单全量曲目）。
Future<void> showKugouPlaylistDetailDialog(
  BuildContext context,
  CoverItem playlist,
) {
  return showKugouTracksDialog(
    context,
    title: playlist.title,
    subtitle: playlist.subtitle,
    cover: playlist.cover,
    loadTracks: (ref) =>
        ref.read(kugouApiProvider).playlistTracksAll(playlist.id),
  );
}

/// 酷狗专辑详情弹窗（专辑歌曲）。
Future<void> showKugouAlbumDialog(BuildContext context, CoverItem album) {
  return showKugouTracksDialog(
    context,
    title: album.title,
    subtitle: album.subtitle,
    cover: album.cover,
    loadTracks: (ref) => ref.read(kugouApiProvider).albumTracks(album.id),
  );
}

/// 酷狗歌手详情弹窗（歌手单曲）。
Future<void> showKugouArtistDialog(BuildContext context, CoverItem artist) {
  return showKugouTracksDialog(
    context,
    title: artist.title,
    subtitle: context.l10n.trackListArtistSongs,
    cover: artist.cover,
    loadTracks: (ref) => ref.read(kugouApiProvider).artistAudios(artist.id),
  );
}

/// 酷狗榜单详情弹窗（榜单歌曲）。
Future<void> showKugouRankDialog(BuildContext context, CoverItem rank) {
  return showKugouTracksDialog(
    context,
    title: rank.title,
    subtitle: rank.subtitle,
    cover: rank.cover,
    loadTracks: (ref) => ref.read(kugouApiProvider).rankTracks(rank.id),
  );
}

/// 打开歌单详情弹窗（拉取全量曲目 + 元信息，进入 [TrackListDialog]）。
Future<void> showPlaylistDetailDialog(
  BuildContext context,
  CoverItem playlist,
) {
  return showKugouTracksDialog(
    context,
    title: playlist.title,
    subtitle: playlist.subtitle,
    cover: playlist.cover,
    loadTracks: (ref) async {
      final detail = await ref
          .read(neteaseApiProvider)
          .playlistDetail(playlist.id);
      return detail.tracks;
    },
  );
}

/// 网易云专辑详情弹窗（专辑曲目；收藏页专辑 tab 用）。
Future<void> showNeteaseAlbumDialog(BuildContext context, CoverItem album) {
  return showKugouTracksDialog(
    context,
    title: album.title,
    subtitle: album.subtitle,
    cover: album.cover,
    loadTracks: (ref) => ref.read(neteaseApiProvider).albumTracks(album.id),
  );
}

/// 网易云歌手详情弹窗（歌手热门歌曲；收藏页歌手 tab 用）。
Future<void> showNeteaseArtistDialog(BuildContext context, CoverItem artist) {
  return showKugouTracksDialog(
    context,
    title: artist.title,
    subtitle: context.l10n.trackListArtistHotSongs,
    cover: artist.cover,
    loadTracks: (ref) => ref.read(neteaseApiProvider).artistHotSongs(artist.id),
  );
}

/// 打开每日推荐弹窗（需登录；未登录返回空列表由 UI 提示）。
Future<void> showDailyRecommendDialog(BuildContext context) {
  final l10n = context.l10n;
  return showKugouTracksDialog(
    context,
    title: l10n.trackListDailyRecommend,
    subtitle: l10n.trackListDailyRecommendSubtitle,
    loadTracks: _loadDailyRecommend,
  );
}

Future<List<Track>> _loadDailyRecommend(WidgetRef ref) async {
  // 每日推荐需登录态；未登录时不请求（避免报错），返回空
  final account = ref.read(neteaseAuthProvider);
  if (account == null) return const [];
  return ref.read(neteaseApiProvider).recommendSongs();
}

/// 曲目列表弹窗：歌单详情 / 每日推荐共用。
///
/// 头部（封面 + 标题 + 副标题 + 播放全部）+ 可播放 SongList。
class TrackListDialog extends ConsumerStatefulWidget {
  const TrackListDialog({
    super.key,
    required this.title,
    this.subtitle,
    this.cover,
    required this.loadTracks,
  });

  final String title;
  final String? subtitle;
  final String? cover;

  /// 加载曲目列表（由调用方决定数据源）。
  final Future<List<Track>> Function(WidgetRef ref) loadTracks;

  @override
  ConsumerState<TrackListDialog> createState() => _TrackListDialogState();
}

class _TrackListDialogState extends ConsumerState<TrackListDialog> {
  late Future<List<Track>> _future;
  bool _resolving = false;

  @override
  void initState() {
    super.initState();
    _future = widget.loadTracks(ref);
  }

  Future<void> _reload() {
    setState(() => _future = widget.loadTracks(ref));
    return _future;
  }

  void _toast(String msg) => toast(msg);

  /// 播放单曲（按平台分发解析播放 URL → 后台转码播放；对齐搜索页链路）。
  Future<void> _playTrack(Track track) async {
    if (_resolving) return;
    setState(() => _resolving = true);
    try {
      final String? url;
      if (track.source == 'kugou' && track.kugou != null) {
        url = await ref.read(kugouApiProvider).resolvePlayUrl(track.kugou!);
      } else if (track.source == 'netease') {
        url = await ref.read(neteaseApiProvider).resolvePlayUrl(track.id);
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

  /// 播放全部（整表作为播放队列）。
  Future<void> _playAll(List<Track> tracks) async {
    if (tracks.isEmpty) return;
    try {
      await ref.read(playbackProvider.notifier).playQueue(tracks);
    } catch (_) {
      // 错误已记入播放日志
    }
  }

  /// 行右键菜单（通用在线曲目菜单）。
  void _onTrackMenu(Track track, Offset global) {
    showTrackContextMenu(
      context,
      ref: ref,
      track: track,
      position: global,
      onPlay: () => _playTrack(track),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    // 选择性订阅（播放位置/FFT 50ms 更新不重建弹窗列表）
    final playingId = ref.watch(playbackProvider.select((s) => s.trackId));
    final isPlaying = ref.watch(playbackProvider.select((s) => s.playing));
    // 列表区域高度随窗口自适应（预留头部空间）
    final window = MediaQuery.sizeOf(context);
    final listHeight = (window.height * 0.6).clamp(300.0, 560.0);

    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 80, vertical: 48),
      // 裁剪整个弹窗画布到 shape 圆角（Dialog 默认 Clip.none）
      clipBehavior: Clip.antiAlias,
      // 图片风格下为毛玻璃（blur(16)），背景图不再清晰透出
      child: GlassDialogSurface(
        radius: BorderRadius.circular(16),
        color: theme.colorScheme.surfaceContainerHigh,
        child: SizedBox(
          // 随窗口自适应：偏好 780 宽，小窗口按比例收缩
          width: (MediaQuery.sizeOf(context).width * 0.68).clamp(560.0, 780.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ── 头部 ─────────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 12, 0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _HeaderCover(cover: widget.cover),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (widget.subtitle != null &&
                              widget.subtitle!.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              widget.subtitle!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                          const SizedBox(height: 12),
                          FutureBuilder<List<Track>>(
                            future: _future,
                            builder: (context, snapshot) {
                              if (snapshot.hasData &&
                                  snapshot.data!.isNotEmpty) {
                                return SButton(
                                  label: l10n.trackListPlayAll,
                                  icon: Icons.play_arrow_rounded,
                                  variant: SButtonVariant.primary,
                                  onPressed: () => _playAll(snapshot.data!),
                                );
                              }
                              return const SizedBox.shrink();
                            },
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: l10n.commonClose,
                      visualDensity: VisualDensity.compact,
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close, size: 18),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              const Divider(height: 1),
              // ── 曲目列表 ─────────────────────────────────────────
              Flexible(
                child: FutureBuilder<List<Track>>(
                  future: _future,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return SizedBox(height: listHeight, child: _spinner());
                    }
                    if (snapshot.hasError) {
                      return SizedBox(
                        height: listHeight,
                        child: _ErrorView(
                          message: l10n.commonLoadFailed('${snapshot.error}'),
                          onRetry: _reload,
                        ),
                      );
                    }
                    final tracks = snapshot.data ?? const <Track>[];
                    if (tracks.isEmpty) {
                      return SizedBox(
                        height: listHeight,
                        child: Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.music_off_outlined,
                                size: 42,
                                color: theme.colorScheme.onSurfaceVariant
                                    .withValues(alpha: 0.5),
                              ),
                              const SizedBox(height: 10),
                              Text(
                                l10n.trackListEmptyDailyLogin(
                                  l10n.brandNetease,
                                ),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }
                    return SizedBox(
                      height: listHeight,
                      child: SongList(
                        items: tracks,
                        playingId: playingId,
                        isPlaying: isPlaying,
                        onPlay: _playTrack,
                        onContextMenu: _onTrackMenu,
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 头部封面（网络图失败回退占位）。
class _HeaderCover extends StatelessWidget {
  const _HeaderCover({this.cover});

  final String? cover;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final placeholder = Container(
      color: theme.colorScheme.primaryContainer.withValues(alpha: 0.5),
      child: Icon(Icons.music_note, size: 40, color: theme.colorScheme.primary),
    );
    final c = cover;
    if (c == null || c.isEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(width: 96, height: 96, child: placeholder),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Image.network(
        c,
        width: 96,
        height: 96,
        fit: BoxFit.cover,
        cacheWidth: (96 * MediaQuery.devicePixelRatioOf(context)).round(),
        cacheHeight: (96 * MediaQuery.devicePixelRatioOf(context)).round(),
        errorBuilder: (_, _, _) => placeholder,
        loadingBuilder: (context, child, progress) =>
            progress == null ? child : placeholder,
      ),
    );
  }
}

/// 酷狗浏览弹窗（排行榜 / 歌单广场等封面网格浏览；点击项进入详情）。
///
/// 点击某项时先关闭弹窗，再通过 [onItemTap] 打开对应详情（避免弹窗叠层）。
Future<void> showKugouBrowseDialog(
  BuildContext context, {
  required String title,
  required Future<List<CoverItem>> Function(WidgetRef ref) loader,
  required void Function(BuildContext context, CoverItem item) onItemTap,
  bool artist = false,
}) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.5),
    barrierDismissible: true,
    builder: (_) => _KugouBrowseDialog(
      title: title,
      loader: loader,
      onItemTap: onItemTap,
      artist: artist,
    ),
  );
}

class _KugouBrowseDialog extends ConsumerStatefulWidget {
  const _KugouBrowseDialog({
    required this.title,
    required this.loader,
    required this.onItemTap,
    this.artist = false,
  });

  final String title;
  final Future<List<CoverItem>> Function(WidgetRef ref) loader;
  final void Function(BuildContext context, CoverItem item) onItemTap;

  /// 歌手浏览（圆形头像）。
  final bool artist;

  @override
  ConsumerState<_KugouBrowseDialog> createState() => _KugouBrowseDialogState();
}

class _KugouBrowseDialogState extends ConsumerState<_KugouBrowseDialog> {
  late Future<List<CoverItem>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.loader(ref);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 80, vertical: 48),
      // 裁剪整个弹窗画布到 shape 圆角（Dialog 默认 Clip.none）
      clipBehavior: Clip.antiAlias,
      // 图片风格下为毛玻璃（blur(16)），背景图不再清晰透出
      child: GlassDialogSurface(
        radius: BorderRadius.circular(16),
        color: theme.colorScheme.surfaceContainerHigh,
        child: SizedBox(
          // 随窗口自适应：偏好 860×660，小窗口按比例收缩并留边距
          width: (MediaQuery.sizeOf(context).width * 0.72).clamp(600.0, 860.0),
          height: (MediaQuery.sizeOf(context).height * 0.84).clamp(
            460.0,
            660.0,
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 12, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.title,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: l10n.commonClose,
                      visualDensity: VisualDensity.compact,
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close, size: 18),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              const Divider(height: 1),
              Expanded(
                child: FutureBuilder<List<CoverItem>>(
                  future: _future,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return _spinner();
                    }
                    if (snapshot.hasError) {
                      return _ErrorView(
                        message: l10n.commonLoadFailed('${snapshot.error}'),
                        onRetry: () =>
                            setState(() => _future = widget.loader(ref)),
                      );
                    }
                    final items = snapshot.data ?? const <CoverItem>[];
                    if (items.isEmpty) {
                      return Center(
                        child: Text(
                          l10n.commonEmptyContent,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      );
                    }
                    return CoverGrid(
                      items: items,
                      maxCrossAxisExtent: 200,
                      artist: widget.artist,
                      childAspectRatio: widget.artist ? 0.82 : 0.78,
                      onTap: (item) {
                        Navigator.of(context).pop();
                        widget.onItemTap(context, item);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 居中加载指示器（列表弹窗共用）。
Widget _spinner() {
  return const Center(
    child: SizedBox(
      width: 26,
      height: 26,
      child: CircularProgressIndicator(strokeWidth: 2.5),
    ),
  );
}

/// 加载错误态（图标 + 文案 + 重试按钮）。
class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline, size: 42, color: theme.colorScheme.error),
          const SizedBox(height: 10),
          Text(message, style: theme.textTheme.bodySmall),
          const SizedBox(height: 14),
          SButton(
            label: l10n.commonRetry,
            icon: Icons.refresh,
            variant: SButtonVariant.secondary,
            onPressed: onRetry,
          ),
        ],
      ),
    );
  }
}
