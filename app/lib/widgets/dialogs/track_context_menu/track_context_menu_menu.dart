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
  final isOnline = track.source == 'netease' || track.source == 'kugou';
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
        SContextMenuItem(
          label: l10n.menuComment,
          icon: EtaIcons.chatOutline,
          onTap: () => showCommentDialog(context, track: track),
        ),
        if (ref.read(appPrefsProvider).developerMode)
          SContextMenuItem(
            label: l10n.menuDownload,
            icon: EtaIcons.downloadOutline,
            onTap: () => _startDownload(context, ref, track),
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
        SContextMenuItem(
          label: l10n.menuTrackDetail,
          icon: EtaIcons.informationOutline,
          onTap: () => showTrackDetailDialog(context, track: track),
        ),
      ],
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
    toast(
      track.source == 'kugou'
          ? l10n.toastLoginRequiredKugou
          : l10n.toastLoginRequiredNetease,
    );
    return;
  }
  toast(controller.isLiked(track) ? l10n.toastLiked : l10n.toastUnliked);
}

Future<void> _startDownload(
  BuildContext context,
  WidgetRef ref,
  Track track,
) async {
  if (track.source == 'qqmusic') {
    toast(context.l10n.qqMusicDownloadUnsupported);
    return;
  }
  if (track.source == 'kugou' && track.kugou == null) {
    toast(context.l10n.toastNoQualityInfo);
    return;
  }
  await downloadTracks(context, ref, [track]);
}
