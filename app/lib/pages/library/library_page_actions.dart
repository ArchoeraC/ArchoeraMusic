// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../library_page.dart';

extension _LibraryPageActions on _LibraryPageState {
  void _play(Track track) {
    final l10n = context.l10n;
    final path = track.localPath;
    if (path == null || path.isEmpty) {
      _toast(l10n.toastMissingLocalPath);
      return;
    }
    try {
      // 队列中已有则跳转，否则建立队列（切歌/播放列表可用）
      ref.read(playbackProvider.notifier).playTrack(track);
    } catch (e) {
      _toast(l10n.toastPlayFailed('$e'));
    }
  }

  /// 本地曲目右键菜单（SContextMenu）。
  void _onTrackMenu(Track track, Offset global) {
    final l10n = context.l10n;
    SContextMenu.show(
      context,
      position: global,
      items: [
        SContextMenuItem(
          label: l10n.menuPlay,
          icon: Icons.play_arrow,
          onTap: () => _play(track),
        ),
        SContextMenuItem(
          label: l10n.menuPlayNext,
          icon: Icons.skip_next_outlined,
          onTap: () {
            ref.read(playbackProvider.notifier).insertToQueue(track);
            _toast(l10n.toastAddedToQueue);
          },
        ),
        SContextMenuItem.divider(),
        SContextMenuItem(
          label: l10n.menuComment,
          icon: Icons.chat_bubble_outline,
          onTap: () => showCommentDialog(context, track: track),
        ),
        SContextMenuItem(
          label: l10n.menuLocateFile,
          icon: Icons.folder_open_outlined,
          onTap: () => _toast(l10n.menuLocateFileComingSoon),
        ),
        SContextMenuItem(
          label: l10n.menuRemoveFromLibrary,
          icon: Icons.delete_outline,
          danger: true,
          onTap: () async {
            final ok = await ref
                .read(libraryStoreProvider.notifier)
                .removeTrackByPath(track.localPath ?? '');
            _toast(ok ? l10n.toastRemovedFromLibrary : l10n.toastRemoveFailed);
          },
        ),
      ],
    );
  }

  void _handleEmptyAddFolder(LibraryState state) {
    if (state.scanDirs.isEmpty) {
      // 无目录：弹出目录管理；有目录：直接开始扫描
      final l10n = context.l10n;
      SDialog.show(
        context,
        title: l10n.libraryScanDirs,
        description: l10n.libraryScanDirsDesc,
        child: const FolderManager(),
        actions: [
          SButton(
            label: l10n.commonDone,
            variant: SButtonVariant.secondary,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      );
    } else {
      ref.read(libraryStoreProvider.notifier).startScan();
    }
  }
}
