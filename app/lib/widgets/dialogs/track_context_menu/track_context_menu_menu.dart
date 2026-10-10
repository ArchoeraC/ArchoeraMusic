// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../track_context_menu.dart';

/// 弹出通用曲目右键菜单。
void showTrackContextMenu(
  BuildContext context, {
  required WidgetRef ref,
  required Track track,
  required Offset position,
  required VoidCallback onPlay,
  Future<void> Function(Track track)? onToggleLike,
  List<SContextMenuItem> extra = const [],
}) {
  // 菜单项可见性由音源注册表声明（不再硬编码平台列表）：
  // - 「红心 / 评论 / 添加到歌单」：NT / KG / Neko；
  // - 「查看歌手 / 详情 / 下载」：NT / KG / QQ / Neko。
  final sp = sourcePlatform(track.source);
  final likeComment = sp.trackMenuLikeComment;
  final canDownload = sp.trackMenuArtistDownload;
  final canViewArtist = sp.trackMenuArtistDownload;
  final liked = ref.read(likeControllerProvider).isLiked(track);
  final toggle = onToggleLike ?? (t) => _defaultToggleLike(context, ref, t);
  final l10n = context.l10n;

  SContextMenu.show(
    context,
    position: position,
    items: [
      SContextMenuItem(
        label: l10n.menuPlay,
        icon: EtaIcons.play,
        onTap: onPlay,
      ),
      SContextMenuItem(
        label: l10n.menuPlayNext,
        icon: EtaIcons.skipForwardOutline,
        onTap: () {
          ref.read(playbackProvider.notifier).insertToQueue(track);
          toast(l10n.toastAddedToQueue);
        },
      ),
      if (likeComment) ...[
        SContextMenuItem.divider(),
        SContextMenuItem(
          label: liked ? l10n.menuUnlike : l10n.menuLike,
          icon: liked ? EtaIcons.heart : EtaIcons.heartOutline,
          onTap: () => toggle(track),
        ),
        SContextMenuItem(
          label: l10n.menuComment,
          icon: EtaIcons.chatOutline,
          onTap: () => showCommentDialog(context, track: track),
        ),
        // 添加到歌单：由注册表适配器声明是否支持（网易云 / Neko）。
        if (collectionPlatform(track.source).playlistManageSupported(ref))
          SContextMenuItem(
            label: l10n.playlistPickTitle,
            icon: EtaIcons.add,
            onTap: () => showPlaylistPickerDialog(
              context,
              source: track.source,
              tracks: [track],
            ),
          ),
      ],
      // 查看歌手 / 媒体详情：在线来源通用（含 QQ）。
      if (canViewArtist) ...[
        SContextMenuItem.divider(),
        // 查看歌手：按来源分发到各平台歌手详情（NT/KG/QQ/NK 均已接通）。
        // Neko 无歌手 id，以名字作 id（与详情弹窗约定一致）。
        if (track.artists.isNotEmpty)
          SContextMenuItem(
            label: l10n.menuViewArtist,
            icon: EtaIcons.userOutline,
            onTap: () {
              final artist = track.artists.first;
              sourcePlatform(track.source).openCover(
                context,
                ref,
                SourceSearchKind.artist,
                CoverItem(
                  id: artist.id ?? artist.name,
                  title: artist.name,
                  cover: track.cover,
                  source: track.source,
                ),
              );
            },
          ),
        SContextMenuItem(
          label: l10n.menuTrackDetail,
          icon: EtaIcons.informationOutline,
          onTap: () => showTrackDetailDialog(context, track: track),
        ),
      ],
      if (canDownload && ref.read(appPrefsProvider).downloadModuleEnabled)
        SContextMenuItem(
          label: l10n.menuDownload,
          icon: EtaIcons.downloadOutline,
          onTap: () => _startDownload(context, ref, track),
        ),
      ...extra,
    ],
  );
}

Future<void> _defaultToggleLike(
  BuildContext context,
  WidgetRef ref,
  Track track,
) async {
  final controller = ref.read(likeControllerProvider);
  final ok = await controller.toggle(track);
  if (!context.mounted) return;
  final l10n = context.l10n;
  if (!ok) {
    toast(likeFailedTextFor(track.source, l10n));
    return;
  }
  toast(controller.isLiked(track) ? l10n.toastLiked : l10n.toastUnliked);
}

Future<void> _startDownload(
  BuildContext context,
  WidgetRef ref,
  Track track,
) async {
  if (track.source == 'kugou' && track.kugou == null) {
    toast(context.l10n.toastNoQualityInfo);
    return;
  }
  await downloadTracks(context, ref, [track]);
}
