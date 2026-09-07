// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/netease/track.dart';
import '../../stores/app_prefs.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import '../../utils/format.dart';
import 'cover_image.dart';
import '../common/anim.dart';
import 'package:archoera_music/eta/icon/eta_icons.dart';

part 'song_row/song_row_view.dart';

/// 红心匹配键：KG用歌曲 hash（搜索条目 id 退化为 hash、歌单条目可能为
/// audio_id，不统一），QM用 **songmid**（Track.id 为数字 songid，
/// NT同用数字 id——不区分来源会让 QQ 曲目误命中NT红心集合），
/// NT用 track.id（与 LikeController 保持一致）。
/// **KG hash 统一转小写**：mobilecdn 搜索返回小写 hash，而「我喜欢」
/// 歌单（v4/get_list_all_file）存大写——大小写敏感 contains 会导致
/// 已收藏歌曲在搜索中误标为非红心（对齐 enrichKugouHashes 的 toLowerCase）。
String songLikeKey(Track t) {
  if (t.source == 'kugou') {
    return (t.kugou?.hash ?? t.id).toLowerCase();
  }
  if (t.source == 'qqmusic') {
    final mid = t.qqmusic?.mid;
    return (mid != null && mid.isNotEmpty) ? mid : t.id;
  }
  return t.id;
}

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
  ConsumerState<SongRow> createState() => _SongRowState();
}

class _SongRowState extends ConsumerState<SongRow> {
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
    final text = prefs.showSubtitle
        ? widget.item.subtitle
        : widget.item.artistNames;
    return text.isEmpty ? l10n.commonUnknownArtist : text;
  }

  @override
  Widget build(BuildContext context) => _buildSongRow(context);

  void _setHover(bool value) {
    setState(() => _hover = value);
  }
}
