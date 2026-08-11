import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/netease/track.dart';
import '../../services/playback/playback_notifier.dart';
import '../../stores/app_prefs.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import '../../utils/format.dart';
import 'cover_image.dart';
import '../common/anim.dart';
import '../common/toast.dart';
import '../dialogs/track_context_menu.dart';

/// 歌曲列表（对齐原项目 `SongList.vue` 精简版）。
///
/// 表头（# / 标题 / 专辑 / 时长）+ 滚动列表；行内封面 + 标题 +
/// 歌手副标题；playingId 高亮（主色背景 + 边框）；悬停显示播放图标
/// 覆盖序号 + 音质角标；右键触发 [onContextMenu]（自绘 SContextMenu）；
/// 触底触发 [onReachBottom]（对齐虚拟列表 reach-bottom）。

/// 红心匹配键：酷狗用歌曲 hash（搜索条目 id 退化为 hash、歌单条目可能为
/// audio_id，不统一），网易云用 track.id（与 LikeController 保持一致）。
String _likeKey(Track t) =>
    t.source == 'kugou' ? (t.kugou?.hash ?? t.id) : t.id;

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
  static const _rowHeight = 68.0;
  static const _reachBottomOffset = 400.0;

  /// 批量选择模式（表头切换为批量操作栏，行内序号变勾选框）。
  bool _batchActive = false;

  /// 已选曲目 id 集合（键与 [likeKey] 一致：酷狗 hash / 网易云 id）。
  final Set<String> _selected = {};

  bool _onScroll(ScrollNotification notification) {
    if (notification.metrics.extentAfter < _reachBottomOffset) {
      widget.onReachBottom?.call();
    }
    return false;
  }

  /// 当前列表中处于选中状态的曲目（按列表顺序）。
  List<Track> get _selectedTracks => [
        for (final t in widget.items)
          if (_selected.contains(_likeKey(t))) t,
      ];

  int get _selectedCount => _selectedTracks.length;

  void _toggleSelect(Track t) {
    final key = _likeKey(t);
    setState(() {
      if (!_selected.remove(key)) _selected.add(key);
    });
  }

  void _selectAll() => setState(() {
        _selected
          ..clear()
          ..addAll(widget.items.map(_likeKey));
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
                style: TextStyle(
                  fontSize: 13,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            _batchIconButton(
              tooltip: l10n.batchInvert,
              icon: Icons.flip,
              onTap: () => setState(() {
                // 反选：仅针对当前列表内的曲目（列表外残留键不参与）
                final inverted = {
                  for (final t in widget.items)
                    if (!_selected.contains(_likeKey(t))) _likeKey(t),
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
            child: Text(l10n.songListTitle,
                style: TextStyle(color: scheme.onSurfaceVariant)),
          ),
          if (widget.showAlbum)
            Expanded(
              child: Text(l10n.songListAlbum,
                  style: TextStyle(color: scheme.onSurfaceVariant)),
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
    return Column(
      children: [
        // 表头（对齐 SongList.vue header 普通模式 / 批量模式切换）
        _buildHeader(theme.colorScheme, l10n),
        const Divider(height: 1),
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: _onScroll,
            child: ListView.builder(
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
                return _SongRow(
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
                      widget.likedIds?.contains(_likeKey(item)) ?? false,
                  onPlay: widget.onPlay,
                  onToggleLike: widget.onToggleLike,
                  onContextMenu: widget.onContextMenu,
                  batchActive: _batchActive,
                  selected: _selected.contains(_likeKey(item)),
                  onToggleSelect: () => _toggleSelect(item),
                );
              },
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
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline),
                  )
                : const SizedBox.shrink(),
      ),
    );
  }
}

/// 单个歌曲行（悬停态独立管理）。
class _SongRow extends ConsumerStatefulWidget {
  const _SongRow({
    required this.item,
    required this.index,
    required this.showIndex,
    required this.showAlbum,
    required this.showDuration,
    required this.showSource,
    required this.isPlaying,
    required this.playingNow,
    required this.liked,
    required this.onPlay,
    this.onToggleLike,
    this.onContextMenu,
    this.batchActive = false,
    this.selected = false,
    this.onToggleSelect,
  });

  final Track item;
  final int index;
  final bool showIndex;
  final bool showAlbum;
  final bool showDuration;
  final bool showSource;
  final bool isPlaying;
  final bool playingNow;
  final bool liked;
  final ValueChanged<Track> onPlay;
  final Future<void> Function(Track)? onToggleLike;
  final void Function(Track, Offset)? onContextMenu;

  /// 批量选择模式（行内序号列变勾选框，行点击切换选择）。
  final bool batchActive;
  final bool selected;
  final VoidCallback? onToggleSelect;

  @override
  ConsumerState<_SongRow> createState() => _SongRowState();
}

class _SongRowState extends ConsumerState<_SongRow> {
  bool _hover = false;

  /// 行背景：播放中主色高亮 → 批量模式已选浅色 → 悬停浅底 → 透明。
  Color _rowColor(Color primary) {
    if (widget.isPlaying) return primary.withValues(alpha: 0.14);
    if (widget.batchActive && widget.selected) {
      return primary.withValues(alpha: 0.08);
    }
    if (_hover) {
      return Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.05);
    }
    return Colors.transparent;
  }

  /// 行边框：播放中主色边框 → 批量模式已选弱边框 → 悬停弱化边框 → 透明。
  Color _rowBorder(Color primary) {
    if (widget.isPlaying) return primary.withValues(alpha: 0.4);
    if (widget.batchActive && widget.selected) {
      return primary.withValues(alpha: 0.3);
    }
    if (_hover) return primary.withValues(alpha: 0.2);
    return Colors.transparent;
  }

  /// 列表副标题文本：歌手 + 可选别名；别名隐藏时仅显示歌手（空则回退）。
  String _subtitleText(AppPrefs prefs, AppLocalizations l10n) {
    final text =
        prefs.showSubtitle ? widget.item.subtitle : widget.item.artistNames;
    return text.isEmpty ? l10n.commonUnknownArtist : text;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final item = widget.item;
    final isPlaying = widget.isPlaying;
    final primary = theme.colorScheme.primary;
    // 强迫症预设：列表标签与副标题显示开关（对齐原项目 preset）
    final prefs = ref.watch(appPrefsProvider);
    final bestQuality = _bestQualityLabel(item, l10n);

    return Listener(
      // 右键 → 自绘上下文菜单（PointerEvent.position 为全局坐标）
      onPointerDown: (e) {
        if (widget.onContextMenu != null &&
            (e.buttons & kSecondaryMouseButton) != 0) {
          widget.onContextMenu!(item, e.position);
        }
      },
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          // 批量模式：行点击切换选择（不做播放）
          onTap: widget.batchActive
              ? widget.onToggleSelect
              : () => widget.onPlay(item),
          child: AnimatedContainer(
            duration: animDuration(
                context, const Duration(milliseconds: 150)),
            height: _SongListState._rowHeight,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: _rowColor(primary),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _rowBorder(primary)),
            ),
            child: Row(
              children: [
                // 批量模式：序号列变勾选框；否则保留原序号/播放态
                if (widget.batchActive)
                  SizedBox(
                    width: 32,
                    child: _SelectCell(
                      selected: widget.selected,
                      onTap: widget.onToggleSelect ?? () {},
                    ),
                  )
                else if (widget.showIndex)
                  SizedBox(
                    width: 32,
                    child: _IndexCell(
                      index: widget.index,
                      isPlaying: isPlaying,
                      playingNow: widget.playingNow,
                      hover: _hover,
                      onPlay: () => widget.onPlay(item),
                    ),
                  ),
                // 信息：封面 + 标题 + 歌手
                Expanded(
                  child: Row(
                    children: [
                      CoverImage(cover: item.cover),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                if (widget.showSource)
                                  Padding(
                                    padding: const EdgeInsets.only(right: 6),
                                    child: _SourceBadge(source: item.source),
                                  ),
                                // 付费角标（VIP / EP；强迫症预设可隐藏）
                                if (!prefs.hideVipTag && item.fee > 0)
                                  Padding(
                                    padding: const EdgeInsets.only(right: 6),
                                    child: _Badge(
                                      label: item.fee == 1 ? 'VIP' : 'EP',
                                      textColor: const Color(0xFFE55B5B),
                                      borderColor: const Color(0xFFE55B5B)
                                          .withValues(alpha: 0.4),
                                    ),
                                  ),
                                if (!prefs.hideQualityTag &&
                                    bestQuality != null)
                                  Padding(
                                    padding: const EdgeInsets.only(right: 6),
                                    child: _Badge(
                                      label: bestQuality,
                                      textColor:
                                          theme.colorScheme.onSurfaceVariant,
                                      background: theme.colorScheme.onSurface
                                          .withValues(alpha: 0.08),
                                    ),
                                  ),
                                Flexible(
                                  child: Text(
                                    item.title,
                                    style: theme.textTheme.bodyLarge?.copyWith(
                                      fontWeight: FontWeight.w500,
                                      color: isPlaying ? primary : null,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 3),
                            Text(
                              // 副标题：歌手 + 可选别名（强迫症预设控制）
                              _subtitleText(prefs, l10n),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: isPlaying
                                    ? primary.withValues(alpha: 0.7)
                                    : theme.colorScheme.onSurfaceVariant,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                // 专辑
                if (widget.showAlbum)
                  Expanded(
                    child: Text(
                      item.album?.name.isNotEmpty == true
                          ? item.album!.name
                          : l10n.commonUnknownAlbum,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: isPlaying
                            ? primary.withValues(alpha: 0.7)
                            : theme.colorScheme.onSurface,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                const SizedBox(width: 28),
                // 时长
                if (widget.showDuration)
                  SizedBox(
                    width: 64,
                    child: Text(
                      formatMs(item.duration),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: isPlaying
                            ? primary.withValues(alpha: 0.6)
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                // 红心（可选：喜欢页 / 收藏场景展示）
                if (widget.onToggleLike != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: _LikeButton(
                      liked: widget.liked,
                      onTap: () => widget.onToggleLike!(item),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      ),
    );
  }
}

/// 行内红心切换按钮（填充红 = 已喜欢；点击不冒泡到行播放）。
class _LikeButton extends StatelessWidget {
  const _LikeButton({required this.liked, required this.onTap});

  final bool liked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: liked ? context.l10n.commonUnlike : context.l10n.commonLike,
      child: InkResponse(
        radius: 18,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: AnimatedSwitcher(
            duration: animDuration(
                context, const Duration(milliseconds: 180)),
            transitionBuilder: (child, animation) =>
                ScaleTransition(scale: animation, child: child),
            child: Icon(
              liked ? Icons.favorite : Icons.favorite_border,
              key: ValueKey(liked),
              size: 17,
              color: liked
                  ? Colors.redAccent
                  : scheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
        ),
      ),
    );
  }
}

/// 序号 / 播放状态单元格：数字（悬停显示播放图标）→ 播放中显示音符图标。
class _IndexCell extends StatelessWidget {
  const _IndexCell({
    required this.index,
    required this.isPlaying,
    required this.playingNow,
    required this.hover,
    required this.onPlay,
  });

  final int index;
  final bool isPlaying;
  final bool playingNow;
  final bool hover;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final Widget base;
    if (isPlaying) {
      base = Icon(playingNow ? Icons.graphic_eq : Icons.music_note,
          size: 18, color: primary);
    } else {
      base = Text(
        '${index + 1}',
        textAlign: TextAlign.center,
        style: theme.textTheme.bodyMedium?.copyWith(
          // 4 位及以上序号缩小字体（如「我喜欢」上千首），
          // 保持序号列固定宽度不溢出
          fontSize: index >= 999 ? 11 : null,
          fontWeight: FontWeight.w700,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    // 悬停：覆盖播放按钮
    return Stack(
      alignment: Alignment.center,
      children: [
        AnimatedOpacity(
          duration: animDuration(
              context, const Duration(milliseconds: 150)),
          opacity: hover ? 0 : 1,
          child: base,
        ),
        AnimatedOpacity(
          duration: animDuration(
              context, const Duration(milliseconds: 150)),
          opacity: hover ? 1 : 0,
          child: Icon(
            isPlaying && playingNow ? Icons.pause : Icons.play_arrow,
            size: 18,
            color: primary,
          ),
        ),
        // 整个单元格可点击播放
        Positioned.fill(
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(onTap: onPlay),
          ),
        ),
      ],
    );
  }
}

/// 批量模式下的勾选单元格（圆形勾选框；点击不冒泡到行播放）。
class _SelectCell extends StatelessWidget {
  const _SelectCell({required this.selected, required this.onTap});

  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Tooltip(
        message: selected
            ? context.l10n.batchSelectAll
            : context.l10n.batchInvert,
        child: InkResponse(
          radius: 18,
          onTap: onTap,
          child: AnimatedContainer(
            duration: animDuration(
                context, const Duration(milliseconds: 150)),
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: selected ? scheme.primary : Colors.transparent,
              border: Border.all(
                color: selected
                    ? scheme.primary
                    : scheme.outline.withValues(alpha: 0.6),
                width: 1.5,
              ),
            ),
            child: selected
                ? Icon(Icons.check, size: 12, color: scheme.onPrimary)
                : null,
          ),
        ),
      ),
    );
  }
}

/// 来源平台小徽标（对齐 SPlayer-Next 列表的平台角标；聚合搜索时区分来源）。
class _SourceBadge extends StatelessWidget {
  const _SourceBadge({required this.source});

  final String source;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (source) {
      'netease' => ('云', const Color(0xFFC20C0C)),
      // 酷狗徽标为蓝底白字
      'kugou' => ('酷', const Color(0xFF00A7E0)),
      _ => ('', Colors.transparent),
    };
    if (label.isEmpty) return const SizedBox.shrink();
    return Container(
      width: 16,
      height: 16,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 10,
          height: 1,
          color: Colors.white,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// 酷狗曲目可用最高音质档标签（Hi-Res/无损/HQ/SQ/LQ；无 kugou 信息返回 null）。
String? _bestQualityLabel(Track t, AppLocalizations l10n) {
  final k = t.kugou;
  if (k == null) return null;
  if (k.hashFor('hi-res') != null) return 'Hi-Res';
  if (k.hashFor('lossless') != null) return l10n.commonLossless;
  if (k.hashFor('hq') != null) return 'HQ';
  if (k.hashFor('sq') != null) return 'SQ';
  if (k.hashFor('lq') != null) return 'LQ';
  return null;
}

/// 文本小徽标（付费 / 音质角标共用：圆角底 + 小字标签）。
class _Badge extends StatelessWidget {
  const _Badge({
    required this.label,
    required this.textColor,
    this.background,
    this.borderColor,
  });

  final String label;
  final Color textColor;
  final Color? background;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(
        color: background,
        border: borderColor == null
            ? null
            : Border.all(color: borderColor!),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 9.5,
          height: 1,
          fontWeight: FontWeight.w600,
          color: textColor,
        ),
      ),
    );
  }
}
