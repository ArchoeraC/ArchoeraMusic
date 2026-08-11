import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/netease/track.dart';
import '../services/playback/playback_notifier.dart';
import '../services/scanner/library_store.dart';
import '../services/scanner/local_track.dart';
import '../../l10n/l10n.dart';
import '../widgets/dialogs/comment_dialog.dart';
import '../widgets/dialogs/folder_manager.dart';
import '../widgets/dialogs/s_context_menu.dart';
import '../widgets/dialogs/s_dialog.dart';
import '../widgets/library/library_empty_state.dart';
import '../widgets/library/library_header.dart';
import '../widgets/list/song_list.dart';
import '../widgets/player/s_controls.dart';
import '../widgets/common/toast.dart';

/// 音乐库页（对齐原项目 Library.vue）：本地曲目列表 + 扫描 +
/// 目录管理 + 搜索。顶栏（标题/操作行/搜索/统计/刮削）已拆到
/// [LibraryHeader]，本页只保留列表体与曲目交互。
class LibraryPage extends ConsumerStatefulWidget {
  const LibraryPage({super.key});

  @override
  ConsumerState<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends ConsumerState<LibraryPage> {
  @override
  void initState() {
    super.initState();
    // 首次进入初始化（读扫描目录 + 载入曲库）并触发一次自动增量扫描
    // （距上次自动扫描 ≥5 分钟才执行；壳层分支切换也会触发同一入口，
    // 内部幂等 + 5 分钟窗口保证不重复扫）
    Future.microtask(
      () => ref.read(libraryStoreProvider.notifier).maybeAutoRefresh(),
    );
  }

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

  void _toast(String msg) {
    if (!mounted) return;
    toast(msg);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(libraryStoreProvider);
    // 选择性订阅（播放位置/FFT 50ms 更新不重建列表）
    final playingId = ref.watch(playbackProvider.select((s) => s.trackId));
    final isPlaying = ref.watch(playbackProvider.select((s) => s.playing));
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    final tracks = state.filteredTracks.map(trackFromRow).toList();
    final notifier = ref.read(libraryStoreProvider.notifier);

    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const LibraryHeader(),
          const Divider(height: 1),
          // ── 曲目列表 / 空状态 ─────────────────────────────────
          if (state.error != null)
            Expanded(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 40,
                      color: scheme.error.withValues(alpha: 0.6),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      state.error!,
                      style: TextStyle(
                        fontSize: 13,
                        color: scheme.onSurfaceVariant,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            )
          else if (state.initialized && state.tracks.isEmpty)
            Expanded(
              child: LibraryEmptyState(
                hasDirs: state.scanDirs.isNotEmpty,
                scanning: state.scanning,
                onAddFolder: () {
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
                    notifier.startScan();
                  }
                },
              ),
            )
          else if (tracks.isEmpty && state.searchQuery.isNotEmpty)
            Expanded(
              child: Center(
                child: Text(
                  l10n.libraryNoMatch,
                  style: TextStyle(fontSize: 13),
                ),
              ),
            )
          else
            Expanded(
              child: SongList(
                items: tracks,
                playingId: playingId,
                isPlaying: isPlaying,
                showAlbum: true,
                showDuration: true,
                onPlay: _play,
                onContextMenu: _onTrackMenu,
              ),
            ),
        ],
      ),
    );
  }
}
