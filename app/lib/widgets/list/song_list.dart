import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/netease/track.dart';
import '../../services/playback/playback_notifier.dart';
import '../../stores/app_prefs.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import '../common/toast.dart';
import '../dialogs/track_context_menu.dart';
import 'scroll_float_actions.dart';
import 'song_row.dart';

/// 歌曲列表（对齐原项目 `SongList.vue` 精简版）。
///
/// 表头（# / 标题 / 专辑 / 时长）+ 滚动列表；行内封面 + 标题 +
/// 歌手副标题；playingId 高亮（主色背景 + 边框）；悬停显示播放图标
/// 覆盖序号 + 音质角标；右键触发 [SongRow.onContextMenu]（自绘
/// SContextMenu）；触底触发 [onReachBottom]（对齐虚拟列表 reach-bottom）。
///
/// 行组件拆在 [song_row.dart]（SongRow / 序号 / 勾选 / 红心 / 徽标）。
class SongList extends ConsumerStatefulWidget {
  const SongList({
    super.key,
    required this.items,
    required this.onPlay,
    this.playingId,
    this.isPlaying = false,
    this.onReachBottom,
    this.hasMore = false,
    this.loadingMore = false,
    this.showIndex = true,
    this.showAlbum = true,
    this.showDuration = true,
    this.showSource = false,
    this.onContextMenu,
    this.likedIds,
    this.onToggleLike,
  });

  final List<Track> items;
  final VoidCallback? onReachBottom;
  final bool hasMore;
  final bool loadingMore;

  /// 当前播放歌曲 id（高亮）。
  final String? playingId;
  final bool isPlaying;

  /// 播放回调（单击行 / 单击序号播放图标）。
  final ValueChanged<Track> onPlay;

  final bool showIndex;
  final bool showAlbum;
  final bool showDuration;

  /// 行内显示来源平台徽标（聚合搜索合并多平台结果时开启）。
  final bool showSource;

  /// 行右键菜单（global 坐标），null 则不启用。
  final void Function(Track, Offset)? onContextMenu;

  /// 已喜欢曲目 id 集合（配合 [onToggleLike] 渲染红心填充态）。
  final Set<String>? likedIds;

  /// 行内红心切换（null 则不显示红心按钮）。
  final Future<void> Function(Track)? onToggleLike;

  @override
  ConsumerState<SongList> createState() => _SongListState();
}

class _SongListState extends ConsumerState<SongList> {
  static const _reachBottomOffset = 400.0;

  /// 列表滚动控制器（供浮动「回到顶部 / 定位播放」按钮使用）。
  final ScrollController _scrollCtrl = ScrollController();

  /// 行间步进（行高 68 + 行外上下 padding 4×2）与列表顶部 padding，
  /// 与 [song_row.dart] 的 SongRow 布局一致，用于定位行偏移计算。
  static const double _songRowExtent = 76.0;
  static const double _songTopPadding = 8.0;

  /// 批量选择模式（表头切换为批量操作栏，行内序号变勾选框）。
  bool _batchActive = false;

  /// 已选曲目 id 集合（键与 [songLikeKey] 一致：酷狗 hash / 网易云 id）。
  final Set<String> _selected = {};

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  /// 当前播放曲目在本列表中的索引（不在列表中则为 -1）。
  int get _playingIndex {
    final id = widget.playingId;
    if (id == null) return -1;
    return widget.items.indexWhere((t) => t.id == id);
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.metrics.extentAfter < _reachBottomOffset) {
      widget.onReachBottom?.call();
    }
    return false;
  }

  /// 当前列表中处于选中状态的曲目（按列表顺序）。
  List<Track> get _selectedTracks => [
    for (final t in widget.items)
      if (_selected.contains(songLikeKey(t))) t,
  ];

  int get _selectedCount => _selectedTracks.length;

  void _toggleSelect(Track t) {
    final key = songLikeKey(t);
    setState(() {
      if (!_selected.remove(key)) _selected.add(key);
    });
  }

  void _selectAll() => setState(() {
    _selected
      ..clear()
      ..addAll(widget.items.map(songLikeKey));
  });

  void _clearAll() => setState(_selected.clear);

  /// 退出批量模式并清空选择。
  void _exitBatch() => setState(() {
    _batchActive = false;
    _selected.clear();
  });

  /// 批量播放：所选曲目按列表顺序建立队列并从第一首开播。
  Future<void> _batchPlay() async {
    final tracks = _selectedTracks;
    if (tracks.isEmpty) return;
    await ref.read(playbackProvider.notifier).playQueue(tracks);
    if (mounted) _exitBatch();
  }

  /// 批量加入播放队列（逐首插入当前曲目之后，保持所选顺序）。
  void _batchAddQueue() {
    final tracks = _selectedTracks;
    if (tracks.isEmpty) return;
    final notifier = ref.read(playbackProvider.notifier);
    for (final t in tracks) {
      notifier.insertToQueue(t);
    }
    toast(context.l10n.toastBatchAddedToQueue(tracks.length));
    if (mounted) _exitBatch();
  }

  /// 批量下载（开发者模式才显示入口）：登录校验 + 一次音质选择 + 逐首入队。
  Future<void> _batchDownload() async {
    final tracks = _selectedTracks;
    if (tracks.isEmpty) return;
    await downloadTracks(context, ref, tracks);
    if (mounted) _exitBatch();
  }

  /// 表头：普通模式（# / 标题 / 专辑 / 时长）+ 批量选择入口；
  /// 批量模式切换为批量操作栏（全选 / 已选数 / 反选 / 播放 / 加入队列 /
  /// 下载 / 退出）。
  Widget _buildHeader(ColorScheme scheme, AppLocalizations l10n) {
    if (_batchActive) {
      final count = _selectedCount;
      final all = widget.items.isNotEmpty && count == widget.items.length;
      final none = count == 0;
      final devMode = ref.watch(appPrefsProvider).developerMode;
      return Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            // 全选（半选态 = 未全选）
            SizedBox(
              width: 36,
              child: Center(
                child: Checkbox(
                  value: all ? true : (none ? false : null),
                  tristate: true,
                  visualDensity: VisualDensity.compact,
                  onChanged: (v) => v == true ? _selectAll() : _clearAll(),
                ),
              ),
            ),
            Expanded(
              child: Text(
                l10n.queueTrackCount(count),
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              ),
            ),
            _batchIconButton(
              tooltip: l10n.batchInvert,
              icon: Icons.flip,
              onTap: () => setState(() {
                // 反选：仅针对当前列表内的曲目（列表外残留键不参与）
                final inverted = {
                  for (final t in widget.items)
                    if (!_selected.contains(songLikeKey(t))) songLikeKey(t),
                };
                _selected
                  ..clear()
                  ..addAll(inverted);
              }),
            ),
            _batchIconButton(
              tooltip: l10n.batchPlay,
              icon: Icons.play_arrow,
              enabled: !none,
              onTap: _batchPlay,
            ),
            _batchIconButton(
              tooltip: l10n.batchAddQueue,
              icon: Icons.queue_music,
              enabled: !none,
              onTap: _batchAddQueue,
            ),
            if (devMode)
              _batchIconButton(
                tooltip: l10n.batchDownload,
                icon: Icons.download_outlined,
                enabled: !none,
                onTap: _batchDownload,
              ),
            _batchIconButton(
              tooltip: l10n.batchExit,
              icon: Icons.close,
              onTap: _exitBatch,
            ),
          ],
        ),
      );
    }
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      alignment: Alignment.centerLeft,
      child: Row(
        children: [
          SizedBox(
            width: 28,
            child: Tooltip(
              message: l10n.batchSelectHint,
              child: InkResponse(
                radius: 14,
                onTap: () => setState(() => _batchActive = true),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(
                    Icons.checklist,
                    size: 16,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
          if (widget.showIndex)
            const SizedBox(
              width: 32,
              child: Text('#', textAlign: TextAlign.center),
            ),
          Expanded(
            child: Text(
              l10n.songListTitle,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ),
          if (widget.showAlbum)
            Expanded(
              child: Text(
                l10n.songListAlbum,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ),
          const SizedBox(width: 28),
          if (widget.showDuration)
            SizedBox(
              width: 64,
              child: Text(l10n.songListDuration, textAlign: TextAlign.center),
            ),
        ],
      ),
    );
  }

  /// 批量操作栏小图标按钮。
  Widget _batchIconButton({
    required String tooltip,
    required IconData icon,
    required VoidCallback onTap,
    bool enabled = true,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: IconButton(
        onPressed: enabled ? onTap : null,
        iconSize: 18,
        visualDensity: VisualDensity.compact,
        color: scheme.onSurfaceVariant,
        disabledColor: scheme.onSurfaceVariant.withValues(alpha: 0.3),
        icon: Icon(icon),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return Stack(
      children: [
        Column(
          children: [
            // 表头（对齐 SongList.vue header 普通模式 / 批量模式切换）
            _buildHeader(theme.colorScheme, l10n),
            const Divider(height: 1),
            Expanded(
              child: NotificationListener<ScrollNotification>(
                onNotification: _onScroll,
                child: ListView.builder(
                  controller: _scrollCtrl,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: widget.items.length + 1,
                  itemBuilder: (context, index) {
                    if (index == widget.items.length) {
                      return _Footer(
                        visible: widget.items.isNotEmpty,
                        loadingMore: widget.loadingMore,
                        hasMore: widget.hasMore,
                      );
                    }
                    final item = widget.items[index];
                    return SongRow(
                      item: item,
                      index: index,
                      showIndex: widget.showIndex,
                      showAlbum: widget.showAlbum,
                      showDuration: widget.showDuration,
                      showSource: widget.showSource,
                      isPlaying: widget.playingId == item.id,
                      playingNow: widget.isPlaying,
                      // 酷狗以 hash 为红心键（与 LikeController 一致）；
                      // 网易云仍用 track.id
                      liked:
                          widget.likedIds?.contains(songLikeKey(item)) ?? false,
                      onPlay: widget.onPlay,
                      onToggleLike: widget.onToggleLike,
                      onContextMenu: widget.onContextMenu,
                      batchActive: _batchActive,
                      selected: _selected.contains(songLikeKey(item)),
                      onToggleSelect: () => _toggleSelect(item),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
        // 右下角浮动按钮组（对齐 SongList.vue `absolute right-6 bottom-5`）：
        // 批量选择模式下整组隐藏（对齐 `!batch.active`）
        Positioned(
          right: 24,
          bottom: 20,
          child: IgnorePointer(
            ignoring: _batchActive,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ScrollToTopButton(controller: _scrollCtrl),
                const SizedBox(height: 12),
                LocatePlayingButton(
                  controller: _scrollCtrl,
                  playingIndex: _playingIndex,
                  itemExtent: _songRowExtent,
                  topPadding: _songTopPadding,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 列表底部状态：加载更多 / 没有更多。
class _Footer extends StatelessWidget {
  const _Footer({
    required this.visible,
    required this.loadingMore,
    required this.hasMore,
  });

  final bool visible;
  final bool loadingMore;
  final bool hasMore;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!visible) return const SizedBox.shrink();
    return SizedBox(
      height: 48,
      child: Center(
        child: loadingMore
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : !hasMore
            ? Text(
                context.l10n.commonNoMore,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              )
            : const SizedBox.shrink(),
      ),
    );
  }
}
