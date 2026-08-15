import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/history/history_store.dart';
import '../services/netease/track.dart';
import '../services/playback/playback_notifier.dart';
import '../stores/providers.dart';
import '../../l10n/l10n.dart';
import '../widgets/dialogs/s_context_menu.dart';
import '../widgets/dialogs/s_dialog.dart';
import '../widgets/player/s_controls.dart';
import '../widgets/list/song_list.dart';
import '../widgets/common/toast.dart';
import '../widgets/dialogs/track_context_menu.dart';

/// 历史页（对齐原项目 History.vue）。
///
/// 本地存储（HistoryStore，同曲去重置顶，上限 500）：
/// 标题 + 总数 + 播放全部 + 清空 + 列表（时间倒序）；点击行播放，
/// 右键可单条移除。
class HistoryPage extends ConsumerStatefulWidget {
  const HistoryPage({super.key});

  @override
  ConsumerState<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends ConsumerState<HistoryPage> {
  List<HistoryEntry> _entries = const [];
  bool _loading = true;
  bool _resolving = false;

  /// 历史变更订阅（IndexedStack 下页面常驻，订阅后任何 record/remove/
  /// clear/trim 即时重载——事件驱动，无轮询/高频监听）。
  StreamSubscription<HistoryChangedEvent>? _changesSub;

  /// 突发变更合并（连播快速切歌时只重载一次，避免逐首整表重读）。
  bool _reloadScheduled = false;

  @override
  void initState() {
    super.initState();
    _changesSub = HistoryStore.changes
        .on<HistoryChangedEvent>()
        .listen((_) => _scheduleReload());
    _load();
  }

  @override
  void dispose() {
    _changesSub?.cancel();
    super.dispose();
  }

  /// 变更事件 → 下一微任务合并重载（异步投递，不阻塞写入方调用链）。
  void _scheduleReload() {
    if (_reloadScheduled) return;
    _reloadScheduled = true;
    Future.microtask(() {
      _reloadScheduled = false;
      _load();
    });
  }

  void _load() {
    final entries = ref.read(historyStoreProvider).entries();
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _loading = false;
    });
  }

  void _toast(String msg) => toast(msg);

  List<Track> get _tracks => _entries.map((e) => e.track).toList();

  /// 播放全部（对齐 History.vue handlePlayAll：playFrom(tracks, 0)）。
  void _playAll() {
    final tracks = _tracks;
    if (tracks.isEmpty) return;
    ref.read(playbackProvider.notifier).playQueue(tracks);
  }

  Future<void> _playTrack(Track track) async {
    if (_resolving) return;
    setState(() => _resolving = true);
    try {
      final String? url;
      if (track.source == 'kugou' && track.kugou != null) {
        url = await ref.read(kugouApiProvider).resolvePlayUrl(track.kugou!);
      } else if (track.source == 'local') {
        url = track.localPath;
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
      await ref.read(playbackProvider.notifier).playNow(track, resolvedUrl: url);
    } catch (e) {
      if (mounted) _toast(context.l10n.trackListPlaySourceFailed('$e'));
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  /// 单条移除（右键菜单）。列表刷新由 [HistoryStore.changes] 事件驱动。
  void _removeEntry(Track track) {
    ref.read(historyStoreProvider).remove(track);
    _toast(context.l10n.pageHistoryRemoved);
  }

  /// 清空全部（确认弹窗）。
  Future<void> _confirmClear() async {
    final l10n = context.l10n;
    final ok = await SDialog.show<bool>(
      context,
      title: l10n.pageHistoryClearTitle,
      description: l10n.pageHistoryClearMessage,
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
          onPressed: () => Navigator.pop(context, true),
          child: Text(l10n.commonClear),
        ),
      ],
      child: const SizedBox.shrink(),
    );
    if (ok != true) return;
    ref.read(historyStoreProvider).clear();
    _toast(l10n.pageHistoryCleared);
  }

  /// 行右键菜单（通用在线曲目菜单 + 页内「从历史移除」）。
  void _onRowMenu(Track track, Offset global) {
    showTrackContextMenu(
      context,
      ref: ref,
      track: track,
      position: global,
      onPlay: () => _playTrack(track),
      extra: [
        SContextMenuItem(
          label: context.l10n.pageHistoryRemove,
          icon: Icons.delete_outline,
          onTap: () => _removeEntry(track),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;
    // 选择性订阅（播放位置/FFT 50ms 更新不重建列表）
    final playingId = ref.watch(playbackProvider.select((s) => s.trackId));
    final isPlaying = ref.watch(playbackProvider.select((s) => s.playing));
    final hasHistory = _entries.isNotEmpty;

    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── 标题 ─────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.sidebarHistory,
                        style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                          color: scheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        hasHistory
                            ? l10n.commonSongCountHint(_entries.length)
                            : l10n.pageHistorySubtitleEmpty,
                        style: TextStyle(
                          fontSize: 13,
                          color: scheme.onSurfaceVariant
                              .withValues(alpha: 0.75),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                if (hasHistory) ...[
                  SButton(
                    label: l10n.commonPlayAll,
                    icon: Icons.play_arrow,
                    variant: SButtonVariant.primary,
                    onPressed: _playAll,
                  ),
                  const SizedBox(width: 10),
                  SButton(
                    label: l10n.commonClear,
                    icon: Icons.delete_outline,
                    variant: SButtonVariant.secondary,
                    onPressed: _confirmClear,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          const Divider(height: 1),
          // ── 内容区 ───────────────────────────────────────────
          Expanded(
            child: _loading
                ? const Center(
                    child: SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    ),
                  )
                : !hasHistory
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.history,
                          size: 48,
                          color: scheme.onSurfaceVariant
                              .withValues(alpha: 0.5),
                        ),
                        const SizedBox(height: 10),
                        Text(l10n.pageHistoryEmpty, style: theme.textTheme.bodyMedium),
                        const SizedBox(height: 4),
                        Text(
                          l10n.pageHistoryEmptyHint,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  )
                : SongList(
                    items: _tracks,
                    playingId: playingId,
                    isPlaying: isPlaying,
                    onPlay: _playTrack,
                    onContextMenu: _onRowMenu,
                  ),
          ),
        ],
      ),
    );
  }
}
