// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 歌词滚动渲染组件（§10.2 UI 层；AMLL 观感简化版）。
///
/// 行为：当前行居中 + 主色放大高亮（周边行渐隐）；播放位置驱动
/// 自动滚动（行切换时一次动画）；点击行 → [onSeek]（毫秒）。
/// 增强歌词：当前行原文按逐字片段（YRC/KRC）做卡拉OK 高亮，
/// 翻译以次行小字显示（[LyricGroup.translation]）。
/// 数据为空时显示占位（对应 Web 端空态）。
///
/// 样式参数（字号 / 行高 / 已唱色 / 未唱色）由播放页从「设置 → 歌词」
/// 偏好传入（对齐原版 desktopLyric 的个性化配置）。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../services/lyrics/lyric_line.dart';
import 'lyrics_v7/lyrics_layout.dart';
import '../../l10n/generated/app_localizations.dart';
import '../common/anim.dart';

part 'lyrics_view/lyrics_view_widgets.dart';

/// 歌词滚动渲染。
class LyricsView extends StatefulWidget {
  const LyricsView({
    super.key,
    required this.groups,
    required this.positionMs,
    this.onSeek,
    this.fontSize = 14,
    this.lineHeight = LyricsView.defaultLineHeight,
    this.playedColor,
    this.unplayedColor,
    this.showTranslation = true,
  });

  final List<LyricGroup> groups;

  /// 当前播放位置（毫秒）。
  final int positionMs;

  /// 点击歌词行 seek（参数 = 行起始毫秒）；null 禁用点击。
  final ValueChanged<int>? onSeek;

  /// 非当前行字号（px；设置「歌词字号」，默认 14）。
  final double fontSize;

  /// 行高（含间距；设置「歌词行距」，默认 44）。
  final double lineHeight;

  /// 当前行颜色（设置「已唱颜色」，默认跟随主题主色）。
  final Color? playedColor;

  /// 非当前行颜色（设置「未唱颜色」，默认主题次级前景）。
  final Color? unplayedColor;

  /// 显示翻译（当前行翻译次行小字；设置「显示翻译」，默认开）。
  final bool showTranslation;

  /// 行高默认值（含间距）。
  static const double defaultLineHeight = 44;

  @override
  State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView> {
  final _controller = ScrollController();

  /// 当前行索引（避免每帧滚动）。
  int _current = -1;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _buildLyricsView(context);

  void _scrollToIndex(int index) {
    // index < 0：播放位置早于第一句歌词（循环回放 / 前奏阶段）——
    // 也滚回首行，否则循环重新播放时歌词停留在上一轮最后位置
    final targetIndex = index < 0 ? 0 : index;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 第 index 行中心滚到视口中心：滚动量恰为 index × 行高
      // （顶部对称留白 half - lineHeight/2 已把偏移抵消）
      final max = _controller.position.maxScrollExtent;
      final target = (targetIndex * widget.lineHeight).clamp(0.0, max);
      _controller.animateTo(
        target,
        duration: animDuration(context, const Duration(milliseconds: 280)),
        curve: Curves.easeOutCubic,
      );
    });
  }
}
