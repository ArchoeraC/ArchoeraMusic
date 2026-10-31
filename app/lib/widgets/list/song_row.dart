// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter/gestures.dart'
    show kSecondaryMouseButton, PointerDeviceKind;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/netease/track.dart';
import '../../services/search/search_highlight.dart';
import '../../services/source/source_platform.dart';
import '../dialogs/collection_platform.dart';
import '../../easter_egg/mouse_dodge.dart';
import '../../stores/app_prefs.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import '../../utils/format.dart';
import 'cover_image.dart';
import '../common/anim.dart';
import 'package:archoera_music/eta/icon/eta_icons.dart';

part 'song_row/song_row_view.dart';

/// 红心匹配键：由「收藏平台」适配器按来源归一
/// （[CollectionPlatform.likeKey]：KG 用 hash 小写、QM 用 songmid、NT/NK 用
/// track.id）——不在此硬编码平台，与 `LikeController` 保持同源。
String songLikeKey(Track t) => collectionPlatform(t.source).likeKey(t);

/// 行高（与 [SongList] 表头高度对齐，行组件内部使用）。
const double _rowHeight = 68.0;

/// 单个歌曲行（悬停态独立管理）。
///
/// 播放中主色高亮 + 边框；悬停显示播放图标覆盖序号；批量模式行内
/// 序号列变勾选框；右键触发 [onContextMenu]；红心按钮可选显示。
class SongRow extends ConsumerStatefulWidget {
  const SongRow({
    super.key,
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
    this.highlightOf,
    this.lyricSnippet,
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

  /// 可选搜索结果高亮：给定展示文本 → 命中区间（标题 / 副标题 / 专辑）。
  ///
  /// 为 `null`（默认）时行渲染与不传时**逐像素一致**（关闭态零成本）；关闭态与
  /// 非搜索态一律传 null。区间由页面侧经 `SearchHighlighter` 记忆化，行内每帧
  /// rebuild 命中缓存、不重复计算（见 `services/search/search_highlight.dart`）。
  final List<MatchRange> Function(String text)? highlightOf;

  /// 可选歌词命中**行内片段**（歌词命中行的命中窗口文本）。
  ///
  /// 为 `null`（默认）时行渲染与不传该参数时**逐像素一致**（关闭态 / 非搜索态
  /// 零成本）；非空时在歌手 / 专辑下方以次要样式单行省略显示（不改变固定行高）。
  /// 片段由页面在**页加载异步路径**算好并缓存，本组件只同步读取（见
  /// `services/search/search_lyric_snippet.dart`）。
  final String? lyricSnippet;

  @override
  ConsumerState<SongRow> createState() => _SongRowState();
}

class _SongRowState extends ConsumerState<SongRow> {
  bool _hover = false;

  /// 触摸长按上下文菜单：按住计时 + 按下位置（触摸没有右键）。
  Timer? _ctxHoldTimer;
  Offset? _ctxHoldPos;

  /// 长按已弹出菜单：抑制松手时紧随的 InkWell tap（避免“弹菜单又播放”）。
  bool _suppressTap = false;

  @override
  void dispose() {
    _ctxHoldTimer?.cancel();
    super.dispose();
  }

  /// 取消触摸长按计时（抬起 / 取消 / 移动超阈值时）。
  void _cancelCtxHold() {
    _ctxHoldTimer?.cancel();
    _ctxHoldTimer = null;
    _ctxHoldPos = null;
  }

  /// 长按松手后的首次 tap 是否应被吞掉（长按已弹菜单）。
  bool consumeLongPressTap() {
    if (!_suppressTap) return false;
    _suppressTap = false;
    return true;
  }

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
    final text = prefs.showSubtitle
        ? widget.item.subtitle
        : widget.item.artistNames;
    return text.isEmpty ? l10n.commonUnknownArtist : text;
  }

  @override
  Widget build(BuildContext context) => MouseDodge(child: _buildSongRow(context));

  void _setHover(bool value) {
    setState(() => _hover = value);
  }
}
