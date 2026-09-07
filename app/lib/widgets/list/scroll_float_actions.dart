// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 歌曲列表浮动操作小组件（对齐 SPlayer-Next SongList 右下角浮动按钮组）：
///
/// - [ScrollToTopButton]：回到顶部。滚动超过 [threshold] 时浮现，
///   点击平滑滚动回列表顶部。
/// - [LocatePlayingButton]：定位播放位置。列表中存在当前播放曲目
///   （[playingIndex] >= 0）时浮现，点击平滑滚动到该行。
///
/// 两个组件均依赖宿主传入的 [ScrollController]（同一滚动容器）；批量
/// 选择模式下由宿主决定是否隐藏整组（对齐 SPlayer-Next `!batch.active`）。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import 'package:archoera_music/eta/icon/eta_icons.dart';

part 'scroll_float_actions/scroll_float_actions_view.dart';

/// 右下角浮动操作组（回到顶部 + 定位播放）。
///
/// 自动隐藏策略：滚动中 / 鼠标悬停热区时显示；停止滚动约 [hideDelay] 后淡出，
/// 淡出期间 [IgnorePointer] 放行下方（如收藏红心）点击——避免遮挡底层控件。
/// 批量选择模式（[batchActive]）下整组隐藏。
class SongListFloatActions extends StatefulWidget {
  const SongListFloatActions({
    super.key,
    required this.controller,
    required this.playingIndex,
    this.itemExtent = 76,
    this.topPadding = 8,
    this.threshold = 100,
    this.batchActive = false,
    this.hideDelay = const Duration(milliseconds: 1200),
  });

  final ScrollController controller;
  final int playingIndex;
  final double itemExtent;
  final double topPadding;
  final double threshold;
  final bool batchActive;
  final Duration hideDelay;

  @override
  State<SongListFloatActions> createState() => _SongListFloatActionsState();
}

class _SongListFloatActionsState extends State<SongListFloatActions> {
  bool _active = false; // 滚动中 / 刚触发动作
  bool _hovered = false; // 鼠标在按钮组上
  Timer? _hideTimer;

  bool get _visible => !widget.batchActive && (_active || _hovered);

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_poke);
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    widget.controller.removeListener(_poke);
    super.dispose();
  }

  /// 任意滚动/程序化滚动触发 → 立即显示并重新计时隐藏。
  void _poke() {
    if (!mounted) return;
    if (!_active) setState(() => _active = true);
    _armHide();
  }

  void _armHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(widget.hideDelay, () {
      if (!mounted) return;
      setState(() {
        _active = false;
        _hovered = false;
      });
    });
  }

  void _onHoverEnter() {
    if (widget.batchActive) return;
    _hideTimer?.cancel();
    if (!_hovered) setState(() => _hovered = true);
  }

  void _onHoverExit() {
    if (!_hovered) return;
    setState(() => _hovered = false);
    if (!_active) _armHide();
  }

  @override
  Widget build(BuildContext context) => _buildSongListFloatActions(context);
}

/// 回到顶部浮动按钮：滚动超过阈值自动浮现，点击平滑回顶。
class ScrollToTopButton extends StatefulWidget {
  const ScrollToTopButton({
    super.key,
    required this.controller,
    this.threshold = 100,
  });

  /// 承载列表的滚动控制器（由宿主创建并传给 ListView）。
  final ScrollController controller;

  /// 滚动超过该像素值才显示（对齐 SPlayer-Next `scrollTop > 100`）。
  final double threshold;

  @override
  State<ScrollToTopButton> createState() => _ScrollToTopButtonState();
}

class _ScrollToTopButtonState extends State<ScrollToTopButton> {
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onScroll);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll() {
    final offset = widget.controller.hasClients
        ? widget.controller.offset
        : 0.0;
    final next = offset > widget.threshold;
    if (next != _visible && mounted) {
      setState(() => _visible = next);
    }
  }

  void _toTop() {
    if (!widget.controller.hasClients) return;
    widget.controller.animateTo(
      0,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) => _buildScrollToTopButton(context);
}

/// 定位播放位置浮动按钮：列表存在当前播放曲目时浮现，点击滚动到该行。
class LocatePlayingButton extends StatelessWidget {
  const LocatePlayingButton({
    super.key,
    required this.controller,
    required this.playingIndex,
    this.itemExtent = 76,
    this.topPadding = 8,
  });

  /// 承载列表的滚动控制器。
  final ScrollController controller;

  /// 当前播放曲目在列表中的索引；< 0 表示不在本列表（隐藏按钮）。
  final int playingIndex;

  /// 行间步进（行高 + 行外上下 padding，SongList 行 = 68 + 8）。
  final double itemExtent;

  /// 列表顶部 padding（滚动目标需补偿，使行顶对齐视口顶）。
  final double topPadding;

  bool get _visible => playingIndex >= 0;

  void _locate() {
    if (!controller.hasClients || !_visible) return;
    final target = playingIndex * itemExtent + topPadding;
    controller.animateTo(
      target,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) => _buildLocatePlayingButton(context);
}
