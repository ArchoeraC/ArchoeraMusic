// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

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

part 'track_list_dialog/track_list_dialog_actions.dart';
part 'track_list_dialog/track_list_dialog_view.dart';

/// 通用KG曲目列表弹窗（歌单 / 专辑 / 歌手单曲 / 榜单复用）。
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

/// QM曲目列表弹窗（歌单 / 专辑 / 歌手单曲复用）。
Future<void> showQqTracksDialog(
  BuildContext context, {
  required String title,
  String? subtitle,
  String? cover,
  required Future<List<Track>> Function(WidgetRef ref) loadTracks,
}) => showKugouTracksDialog(
  context,
  title: title,
  subtitle: subtitle,
  cover: cover,
  loadTracks: loadTracks,
);

/// QM歌单详情弹窗（song_list 全量曲目）。
Future<void> showQqPlaylistDetailDialog(
  BuildContext context,
  CoverItem playlist,
) {
  return showQqTracksDialog(
    context,
    title: playlist.title,
    subtitle: playlist.subtitle,
    cover: playlist.cover,
    loadTracks: (ref) async {
      final detail = await ref
          .read(qqMusicApiProvider)
          .playlistTracks(playlist.id, cover: playlist.cover);
      return detail;
    },
  );
}

/// QM专辑详情弹窗（专辑曲目）。
Future<void> showQqAlbumDetailDialog(BuildContext context, CoverItem album) {
  return showQqTracksDialog(
    context,
    title: album.title,
    subtitle: album.subtitle,
    cover: album.cover,
    loadTracks: (ref) async {
      final id = album.id;
      final tracks = await ref.read(qqMusicApiProvider).albumTracks(id);
      return tracks;
    },
  );
}

/// QM歌手详情弹窗（歌手热门曲目）。
Future<void> showQqArtistDetailDialog(BuildContext context, CoverItem artist) {
  return showQqTracksDialog(
    context,
    title: artist.title,
    subtitle: context.l10n.trackListArtistHotSongs,
    cover: artist.cover,
    loadTracks: (ref) => ref.read(qqMusicApiProvider).artistSongs(artist.id),
  );
}

/// KG歌单详情弹窗（公开歌单全量曲目）。
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

/// KG专辑详情弹窗（专辑歌曲）。
Future<void> showKugouAlbumDialog(BuildContext context, CoverItem album) {
  return showKugouTracksDialog(
    context,
    title: album.title,
    subtitle: album.subtitle,
    cover: album.cover,
    loadTracks: (ref) => ref.read(kugouApiProvider).albumTracks(album.id),
  );
}

/// KG歌手详情弹窗（歌手单曲）。
Future<void> showKugouArtistDialog(BuildContext context, CoverItem artist) {
  return showKugouTracksDialog(
    context,
    title: artist.title,
    subtitle: context.l10n.trackListArtistSongs,
    cover: artist.cover,
    loadTracks: (ref) => ref.read(kugouApiProvider).artistAudios(artist.id),
  );
}

/// KG榜单详情弹窗（榜单歌曲）。
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

/// NT专辑详情弹窗（专辑曲目；收藏页专辑 tab 用）。
Future<void> showNeteaseAlbumDialog(BuildContext context, CoverItem album) {
  return showKugouTracksDialog(
    context,
    title: album.title,
    subtitle: album.subtitle,
    cover: album.cover,
    loadTracks: (ref) => ref.read(neteaseApiProvider).albumTracks(album.id),
  );
}

/// NT歌手详情弹窗（歌手热门歌曲；收藏页歌手 tab 用）。
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

  @override
  Widget build(BuildContext context) => _buildTrackListDialog(context);
}

/// KG浏览弹窗（排行榜 / 歌单广场等封面网格浏览；点击项进入详情）。
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

  void _reloadBrowse() {
    setState(() => _future = widget.loader(ref));
  }

  @override
  Widget build(BuildContext context) => _buildBrowseDialog(context);
}
