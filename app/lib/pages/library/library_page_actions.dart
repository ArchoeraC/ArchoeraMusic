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
      _toast(l10n.toastPlayFailed(msg: '$e'));
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
          icon: EtaIcons.play,
          onTap: () => _play(track),
        ),
        SContextMenuItem(
          label: l10n.menuPlayNext,
          icon: EtaIcons.skipForwardOutline,
          onTap: () {
            ref.read(playbackProvider.notifier).insertToQueue(track);
            _toast(l10n.toastAddedToQueue);
          },
        ),
        SContextMenuItem.divider(),
        SContextMenuItem(
          label: l10n.menuComment,
          icon: EtaIcons.chatOutline,
          onTap: () => showCommentDialog(context, track: track),
        ),
        SContextMenuItem(
          label: l10n.menuLocateFile,
          icon: EtaIcons.folderOpenOutline,
          onTap: () => _revealFile(track),
        ),
        SContextMenuItem(
          label: l10n.menuRemoveFromLibrary,
          icon: EtaIcons.deleteOutline,
          danger: true,
          onTap: () async {
            final ok = await ref
                .read(libraryStoreProvider.notifier)
                .removeTrackByPath(track.localPath ?? '');
            _toast(ok ? l10n.toastRemovedFromLibrary : l10n.toastRemoveFailed);
          },
        ),
        // 直接删除曲目文件（磁盘）并从曲库移除：危险操作，二次确认。
        SContextMenuItem(
          label: l10n.menuDeleteFile,
          icon: EtaIcons.wastebasketOutline,
          danger: true,
          onTap: () => _deleteFile(track),
        ),
      ],
    );
  }

  /// 删除曲目文件（磁盘）并从曲库移除（危险操作，需确认）。
  Future<void> _deleteFile(Track track) async {
    final l10n = context.l10n;
    final path = track.localPath;
    if (path == null || path.isEmpty) {
      _toast(l10n.toastMissingLocalPath);
      return;
    }
    final confirmed = await SDialog.show<bool>(
      context,
      title: l10n.libraryDeleteFileTitle,
      description: l10n.libraryDeleteFileMessage(name: track.title),
      width: 440,
      child: const SizedBox.shrink(),
      actions: [
        SButton(
          label: l10n.commonCancel,
          variant: SButtonVariant.secondary,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        SButton(
          label: l10n.libraryDeleteFileConfirm,
          variant: SButtonVariant.error,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
    if (confirmed != true || !mounted) return;
    final done = await ref
        .read(libraryStoreProvider.notifier)
        .deleteTrackFile(path);
    if (!mounted) return;
    _toast(done ? l10n.toastFileDeleted : l10n.toastDeleteFileFailed);
  }

  /// 在系统文件管理器中定位曲目文件（走平台桥接，零子进程）。
  void _revealFile(Track track) {
    final l10n = context.l10n;
    final path = track.localPath;
    if (path == null || path.isEmpty) {
      _toast(l10n.toastMissingLocalPath);
      return;
    }
    final rc = PlatformCapabilities.instance().revealPath(path);
    if (rc != aplOk) {
      _toast(l10n.toastRevealFileFailed);
    }
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
