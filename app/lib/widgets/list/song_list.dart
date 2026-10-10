// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/netease/track.dart';
import '../../services/playback/playback_notifier.dart';
import '../../stores/app_prefs.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import '../common/ink_clip.dart';
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
    this.totalCount,
    this.itemAt,
    this.onMissingIndex,
    this.playingIndexOverride,
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
    this.loadAllItems,
    this.onBatchEditMetadata,
    this.onBatchAddToPlaylist,
  });

  final List<Track> items;

  /// 窗口模式：总行数（含未驻留页）。非 null 时列表按「全局 index 0..totalCount-1」
  /// 渲染，[items] 退化为非窗口模式的回退；为 null 时按 [items] 全量渲染（默认）。
  final int? totalCount;

  /// 窗口模式：按全局 index 取行；未驻留返回 null（UI 渲染轻量占位）。
  final Track? Function(int index)? itemAt;

  /// 窗口模式：全局 index 未驻留时回调（用于异步取页）。
  ///
  /// 由 itemBuilder 在 build 期间调用；实现方需自行把状态变更延后
  /// （如 `scheduleMicrotask`），不得在 build 中同步修改 provider。
  final void Function(int index)? onMissingIndex;

  /// 窗口模式：覆盖定位播放按钮所需的全局 index（此时 [items] 非全量）。
  final int? playingIndexOverride;

  final VoidCallback? onReachBottom;
  final bool hasMore;
  final bool loadingMore;

  /// 可选：批量模式「全选」时加载**全量**匹配曲目（分页列表场景）。
  ///
  /// 为 null 时「全选」仅选择当前 [items]（已加载窗口）；非 null 时按返回值
  /// 选择全部匹配曲目（如整库 / 整个搜索结果），UI 仍只渲染窗口——兼顾
  /// 「全选 = 全库」语义与虚拟化的内存收益。全量仅在批量模式期间驻留。
  final Future<List<Track>> Function()? loadAllItems;

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

  /// 批量模式「编辑元数据」回调（null 则不显示该按钮）。
  ///
  /// 宿主实现弹窗与落盘（本地库页经音源注册表能力接入，见
  /// `services/source/metadata_editor.dart` 的 `MetadataEditor`）；通用列表
  /// （我喜欢 / 搜索结果）不传 → 不显示，避免对在线曲目误暴露能力。
  final Future<void> Function(List<Track> tracks)? onBatchEditMetadata;

  /// 批量「添加到歌单」回调（null → 不显示该按钮）。
  ///
  /// 仅网易云曲目场景由宿主接入（目标为 NT 自建歌单）；其余来源不传。
  final Future<void> Function(List<Track> tracks)? onBatchAddToPlaylist;

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

  /// 尾项（加载中 / 已到底提示）固定高度；列表为空时尾项收为 0。
  static const double _songFooterExtent = 48.0;

  /// 批量选择模式（表头切换为批量操作栏，行内序号变勾选框）。
  bool _batchActive = false;

  /// 已选曲目 id 集合（键与 [songLikeKey] 一致：KG hash / NT id）。
  final Set<String> _selected = {};

  /// 窗口模式下已选曲目（键 → 行 + 全局 index）。
  ///
  /// 页缓存会淘汰远端页，仅靠 [SongList.items] 无法解析已滚出视口的选中项；
  /// 记下 Track 本体后，物化选择 / 批量操作不再随淘汰丢失。
  final Map<String, ({Track track, int index})> _picked = {};

  /// 「全选」覆盖全量（经 [SongList.loadAllItems] 载入）而非仅窗口。
  bool _selectAllActive = false;

  /// 全选模式下缓存的全部匹配曲目（退出批量 / 物化选择后释放）。
  List<Track>? _allItems;

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  /// 当前播放曲目在本列表中的索引（不在列表中则为 -1）。
  ///
  /// 窗口模式下 [SongList.items] 非全量，由宿主的 [SongList.playingIndexOverride]
  /// 提供全局 index。
  int get _playingIndex {
    final override = widget.playingIndexOverride;
    if (override != null) return override;
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

  /// 当前选中的曲目（按全局 index / 源顺序）。
  ///
  /// - 全选进行中（全量未就绪）：空，避免误触批量操作；
  /// - 全选模式：全量；
  /// - 显式集合：在 [SongList.loadAllItems] 缓存的全量（若已载入）或窗口内命中项；
  ///   窗口模式（[SongList.totalCount] 非空）下用 [_picked] 解析，避免页淘汰丢选择。
  List<Track> get _selectedTracks {
    if (_selectAllActive && _allItems == null) return const [];
    if (_allItems != null) {
      final all = _allItems!;
      return [
        for (final t in all)
          if (_selectAllActive || _selected.contains(songLikeKey(t))) t,
      ];
    }
    if (widget.totalCount != null) {
      final picks = _picked.values.toList()
        ..sort((a, b) => a.index.compareTo(b.index));
      return [for (final p in picks) p.track];
    }
    return [
      for (final t in widget.items)
        if (_selected.contains(songLikeKey(t))) t,
    ];
  }

  /// 已选数量。
  int get _selectedCount => _selectedTracks.length;

  /// 表头全选态：全量已选，或当前比对范围内全部命中。
  bool get _allSelected {
    if (_selectAllActive) return _allItems != null;
    // 窗口模式下 items 非全量，用全局 totalCount 判定全选态。
    final total = _allItems?.length ?? widget.totalCount ?? widget.items.length;
    return total > 0 && _selectedCount == total;
  }

  @override
  Widget build(BuildContext context) => _buildSongList(context);
}
