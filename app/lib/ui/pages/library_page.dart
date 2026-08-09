import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/netease/track.dart';
import '../../core/playback/playback_notifier.dart';
import '../../core/scanner/library_store.dart';
import '../../core/scanner/local_track.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import '../widgets/comment_dialog.dart';
import '../widgets/folder_manager.dart';
import '../widgets/s_controls.dart';
import '../widgets/s_context_menu.dart';
import '../widgets/s_dialog.dart';
import '../widgets/song_list.dart';
import '../widgets/toast.dart';

/// 音乐库页（对齐原项目 Library.vue）：本地曲目列表 + 扫描 +
/// 目录管理 + 搜索。
class LibraryPage extends ConsumerStatefulWidget {
  const LibraryPage({super.key});

  @override
  ConsumerState<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends ConsumerState<LibraryPage> {
  @override
  void initState() {
    super.initState();
    // 首次进入初始化（读扫描目录 + 载入曲库）
    Future.microtask(() => ref.read(libraryStoreProvider.notifier).init());
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

  void _playAll(List<Track> tracks) {
    final l10n = context.l10n;
    if (tracks.isEmpty) return;
    try {
      ref.read(playbackProvider.notifier).playQueue(tracks);
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

  String _formatSize(int bytes) {
    if (bytes <= 0) return '';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var v = bytes.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(v >= 100 ? 0 : 1)} ${units[i]}';
  }

  String _formatDuration(int ms, AppLocalizations l10n) {
    final totalSec = ms ~/ 1000;
    final h = totalSec ~/ 3600;
    final m = (totalSec % 3600) ~/ 60;
    final s = totalSec % 60;
    if (h > 0) return l10n.libraryHoursMinutes(h, m);
    if (m > 0) return l10n.libraryMinutes(m);
    return l10n.librarySeconds(s);
  }

  void _openFolders() {
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
  }

  void _openMediaStats(LibraryState state) {
    final l10n = context.l10n;
    SDialog.show(
      context,
      title: l10n.libraryMediaStats,
      description: l10n.libraryMediaStatsDesc,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _statRow(l10n.libraryStatTracks, l10n.libraryStatTrackCount(state.tracks.length)),
          _statRow(
            l10n.libraryStatDuration,
            _formatDuration(
              state.tracks.fold(0, (sum, t) => sum + t.durationMs),
              l10n,
            ),
          ),
          _statRow(l10n.libraryStatSize, _formatSize(state.totalSizeBytes)),
          _statRow(l10n.libraryScanDirs, l10n.libraryScanDirCount(state.scanDirs.length)),
        ],
      ),
      actions: [
        SButton(
          label: l10n.commonClose,
          variant: SButtonVariant.secondary,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }

  Widget _statRow(String label, String value) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(fontSize: 13.5, color: scheme.onSurfaceVariant),
            ),
          ),
          Text(
            value,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
        ],
      ),
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
          // ── 顶栏 ──────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 18, 24, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 标题 + 统计 / 扫描进度
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      l10n.sidebarLibrary,
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                        color: scheme.onSurface,
                      ),
                    ),
                    const SizedBox(width: 14),
                    _buildStatus(state, scheme, l10n),
                  ],
                ),
                const SizedBox(height: 14),
                // 操作行 + 搜索
                Row(
                  children: [
                    SButton(
                      label: l10n.commonPlayAll,
                      icon: Icons.play_arrow_rounded,
                      variant: SButtonVariant.primary,
                      onPressed: tracks.isEmpty ? null : () => _playAll(tracks),
                    ),
                    const SizedBox(width: 8),
                    // 扫描（旋转动画）
                    SizedBox(
                      width: 36,
                      height: 36,
                      child: AnimatedRotation(
                        turns: state.scanning ? 1 : 0,
                        duration: const Duration(milliseconds: 400),
                        curve: Curves.linear,
                        child: SButton(
                          label: '',
                          circle: true,
                          icon: Icons.refresh,
                          variant: SButtonVariant.secondary,
                          onPressed: state.scanning
                              ? notifier.cancelScan
                              : (state.scanDirs.isEmpty
                                    ? null
                                    : () => notifier.startScan()),
                          loading: state.scanning,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // 更多菜单
                    PopupMenuButton<String>(
                      tooltip: l10n.commonMore,
                      position: PopupMenuPosition.under,
                      offset: const Offset(0, 4),
                      onSelected: (key) {
                        switch (key) {
                          case 'folders':
                            _openFolders();
                            break;
                          case 'stats':
                            _openMediaStats(state);
                            break;
                        }
                      },
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: 'folders',
                          height: 40,
                          child: Row(
                            children: [
                              Icon(Icons.folder_outlined, size: 17),
                              SizedBox(width: 10),
                              Text(l10n.libraryScanDirs),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: 'stats',
                          height: 40,
                          child: Row(
                            children: [
                              Icon(Icons.pie_chart_outline, size: 17),
                              SizedBox(width: 10),
                              Text(l10n.libraryMediaStats),
                            ],
                          ),
                        ),
                      ],
                      child: const SizedBox(
                        width: 36,
                        height: 36,
                        child: Center(child: Icon(Icons.more_horiz, size: 20)),
                      ),
                    ),
                    const Spacer(),
                    SInput(
                      width: 190,
                      hintText: l10n.librarySearchHint,
                      prefixIcon: Icons.search,
                      clearable: true,
                      onChanged: (q) => notifier.setSearchQuery(q),
                    ),
                  ],
                ),
              ],
            ),
          ),
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
              child: _EmptyLibrary(
                hasDirs: state.scanDirs.isNotEmpty,
                scanning: state.scanning,
                onAddFolder: () {
                  if (state.scanDirs.isEmpty) {
                    _openFolders();
                  } else {
                    notifier.startScan();
                  }
                },
              ),
            )
          else if (tracks.isEmpty && state.searchQuery.isNotEmpty)
            Expanded(
              child: Center(
                child: Text(l10n.libraryNoMatch, style: TextStyle(fontSize: 13)),
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

  /// 标题旁的状态区：扫描进度 / 曲目统计（对齐原项目 Transition 切换）。
  Widget _buildStatus(LibraryState state, ColorScheme scheme, AppLocalizations l10n) {
    final Widget child;
    if (state.scanning) {
      final percent = state.scanPercent;
      child = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 13,
            height: 13,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Text(
            percent == null
                ? (state.scanCurrent.isEmpty ? l10n.libraryScanningFiles : state.scanCurrent)
                : '${(percent * 100).toStringAsFixed(0)}%'
                      ' · ${state.scanned}/${state.total}',
            style: TextStyle(
              fontSize: 13,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.75),
            ),
          ),
        ],
      );
    } else if (state.initialized && state.tracks.isNotEmpty) {
      final size = _formatSize(state.totalSizeBytes);
      child = Text(
        l10n.libraryTrackCount(state.tracks.length, size.isEmpty ? '' : ' · $size'),
        style: TextStyle(
          fontSize: 13,
          color: scheme.onSurfaceVariant.withValues(alpha: 0.75),
        ),
      );
    } else {
      child = const SizedBox.shrink();
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: child,
    );
  }
}

/// 空库状态：无目录 → 引导添加；有目录未扫描 → 引导扫描。
class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary({
    required this.hasDirs,
    required this.scanning,
    required this.onAddFolder,
  });

  final bool hasDirs;
  final bool scanning;
  final VoidCallback onAddFolder;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: scheme.primaryContainer.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Icon(
              Icons.library_music_outlined,
              size: 34,
              color: scheme.primary,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            hasDirs ? l10n.libraryEmptyWaitScan : l10n.libraryEmpty,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            hasDirs ? l10n.libraryEmptyScanHint : l10n.libraryEmptyAddHint,
            style: TextStyle(
              fontSize: 12.5,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.75),
            ),
          ),
          const SizedBox(height: 20),
          SButton(
            label: hasDirs ? l10n.libraryScanNow : l10n.libraryAddFolder,
            icon: hasDirs ? Icons.refresh : Icons.create_new_folder_outlined,
            variant: SButtonVariant.primary,
            loading: scanning,
            onPressed: scanning ? null : onAddFolder,
          ),
        ],
      ),
    );
  }
}
