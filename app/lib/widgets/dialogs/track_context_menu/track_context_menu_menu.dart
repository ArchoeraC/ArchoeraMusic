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
  final isOnline =
      track.source == 'netease' ||
      track.source == 'kugou' ||
      track.source == 'neko';
  // 可下载来源：KG/NT（Rust 自研）+ QQMusic/Neko（Dart 播放管线回退）。
  final canDownload = isOnline || track.source == 'qqmusic';
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
      if (isOnline) ...[
        SContextMenuItem.divider(),
        SContextMenuItem(
          label: liked ? l10n.menuUnlike : l10n.menuLike,
          icon: liked ? EtaIcons.heart : EtaIcons.heartOutline,
          onTap: () => toggle(track),
        ),
        if (track.source != 'neko')
          SContextMenuItem(
            label: l10n.menuComment,
            icon: EtaIcons.chatOutline,
            onTap: () => showCommentDialog(context, track: track),
          ),
        SContextMenuItem.divider(),
        if (track.source == 'netease' &&
            track.artists.isNotEmpty &&
            track.artists.first.id != null)
          SContextMenuItem(
            label: l10n.menuViewArtist,
            icon: EtaIcons.userOutline,
            onTap: () {
              final artist = track.artists.first;
              showNeteaseArtistDialog(
                context,
                CoverItem(
                  id: artist.id!,
                  title: artist.name,
                  cover: track.cover,
                ),
              );
            },
          ),
        // Neko 无歌手 id，只能用名字搜索；点击查看该歌手曲目。
        if (track.source == 'neko' && track.artists.isNotEmpty)
          SContextMenuItem(
            label: l10n.menuViewArtist,
            icon: EtaIcons.userOutline,
            onTap: () {
              final artist = track.artists.first;
              showNekoArtistDialog(
                context,
                CoverItem(id: artist.name, title: artist.name),
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
    toast(switch (track.source) {
      'kugou' => l10n.toastLoginRequiredKugou,
      'qqmusic' => l10n.toastQqLikeSyncFailed,
      'neko' => l10n.toastLoginRequiredNeko,
      _ => l10n.toastLoginRequiredNetease,
    });
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
