// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// AMLL 歌词墙引擎 —— 稳定实现（行渲染对齐原版 LyricsView 的中文/居中逻辑）。
///
/// 滚动通道：ListView + ScrollController（可回滚、无上漂）。当前行默认锚定
/// 视口 50%（可经 alignFraction 调节）。行渲染照搬原版 _Line：
///   Container(height=lineHeight, alignment:center) + 居中 Column；
///   AnimatedDefaultTextStyle：当前行 fontSize+3 / w600 / 主色，非当前行
///   fontSize / 未唱色×inactiveAlpha；翻译小字 fontSize-4、主色×0.75；
///   有字级片段 → 卡拉 OK 逐字（已唱实色/未唱主色×0.4），无片段整行文本；
///   点击行 seek。
/// 顶部叠加上下渐隐 ShaderMask；性能模式走瞬移。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../services/lyrics/lyric_line.dart';

part 'amll_lyric_wall/amll_lyric_wall_view.dart';

/// AMLL 弹簧预设保留。
const Map<String, (double, double, double)> amllSpringPresets = {
  'default': (1.0, 24.0, 180.0),
  'smooth': (1.0, 18.0, 110.0),
  'responsive': (1.0, 30.0, 420.0),
  'jello': (1.2, 8.0, 130.0),
  'heavy': (2.4, 20.0, 120.0),
};

class AmllLyricWall extends StatefulWidget {
  const AmllLyricWall({
    super.key,
    required this.groups,
    required this.positionMs,
    required this.onSeek,
    this.fontSize = 18,
    this.lineHeight = 52,
    this.playedColor = const Color(0xFF4DA3FF),
    this.unplayedColor = const Color(0xFF9AA1B5),
    this.showTranslation = true,
    this.alignFraction = 0.5,
    this.inactiveAlpha = 0.45,
    this.wordSweep = true,
    this.hidePassed = false,
    this.enableScale = true,
    this.springPreset = 'default',
    this.animate = true,
  });

  final List<LyricGroup> groups;
  final int positionMs;
  final ValueChanged<int> onSeek;

  final double fontSize;
  final double lineHeight;
  final Color playedColor;
  final Color unplayedColor;
  final bool showTranslation;

  /// 激活行锚定（0~1，默认 0.5 = 视口居中，同原版）。
  final double alignFraction;

  /// 非当前行透明度（0~1，默认 0.45，可读性同原版 0.55 档）。
  final double inactiveAlpha;

  /// 逐字卡拉 OK。
  final bool wordSweep;

  /// 隐藏已唱过的行。
  final bool hidePassed;

  /// 非当前行缩小（默认 0.97）。
  final bool enableScale;

  /// 弹簧预设（保留）。
  final String springPreset;

  /// false = 性能模式：瞬移。
  final bool animate;

  @override
  State<AmllLyricWall> createState() => _AmllLyricWallState();
}

class _AmllLyricWallState extends State<AmllLyricWall> {
  late final ScrollController _controller;
  int _current = -1;
  double _viewH = 0;
  double _padTop = 0;
  double _padBottom = 0;
  bool _everPlaced = false;

  int get _activeIndex => lyricIndexAt(widget.groups, widget.positionMs);

  @override
  void initState() {
    super.initState();
    _controller = ScrollController();
    _current = _activeIndex;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(AmllLyricWall oldWidget) {
    super.didUpdateWidget(oldWidget);
    final idx = _activeIndex;
    if (idx != _current || oldWidget.groups != widget.groups) {
      _current = idx;
      _ensureVisible(idx);
    }
  }

  @override
  Widget build(BuildContext context) => _buildAmllLyricWall(context);
}
