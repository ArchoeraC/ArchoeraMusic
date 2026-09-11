// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:material_ui/material_ui.dart';
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
import 'package:archoera_music/eta/icon/eta_icons.dart';

part 'song_list/song_list_actions.dart';
part 'song_list/song_list_view.dart';

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

  /// 已选曲目 id 集合（键与 [songLikeKey] 一致：KG hash / NT id）。
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

  @override
  Widget build(BuildContext context) => _buildSongList(context);
}
