// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 普通歌词滚动渲染（非 AMLL 物理歌词墙）。
///
/// 2026-11-09 重写：不再用 `ListView` + 每次换行 `animateTo(easeOutCubic)`，
/// 改为**单控制器连续滚动**的自绘视口：
///
/// - 行位置只由一个 `AnimationController` 的线性插值决定（无过冲、无逐行
///   重新加速），符合人眼对连续阅读运动的预期；
/// - 只构建视口 ± 一屏的行，行高用 `TextPainter` 实测并缓存，位置 tick
///   （~20Hz）不会重新排版；
/// - 当前行按「离视口中心的距离」连续变化颜色 / 缩放 / 透明度，换行时
///   不会出现整行突然变大变色的跳变；
/// - 逐字歌词用**连续扫亮**（按片段时长插值），而不是「唱到就整字换色」；
/// - 上下渐隐直接乘进每行颜色（零离屏层），不再依赖全屏 `ShaderMask`；
/// - 保留滚轮 / 拖拽手动浏览，3 秒无操作后按当前播放位置线性回中。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/gestures.dart' show PointerScrollEvent;

import '../../l10n/l10n.dart';
import '../../services/lyrics/lyric_line.dart';
import '../../theme/motion.dart';
import 'lyrics_edge_fade.dart';
import 'lyrics_v7/lyrics_layout.dart';

import 'package:archoera_music/eta/icon/eta_icons.dart';

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
    this.showRomanization = false,
    this.fontWeight = FontWeight.w600,
    this.currentFontSize,
    this.inactiveFontWeight = FontWeight.w400,
    this.inactiveScale = 1.0,
    this.unplayedAlpha = 0.55,
    this.textAlign = TextAlign.center,
    this.fadeEdges = false,
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

  /// 显示音译（当前行罗马音次行小字；设置「显示音译」，默认关）。
  final bool showRomanization;

  /// 当前行字重（设置「歌词字重」，默认半粗）。
  final FontWeight fontWeight;

  /// 当前行字号（null = [fontSize] + 3，保持旧行为）。
  ///
  /// Vutron 经典布局当前行与普通行同字号（视觉缩放由 [inactiveScale] 表达）。
  final double? currentFontSize;

  /// 非当前行字重（默认 w400；Vutron 布局用 w600）。
  final FontWeight inactiveFontWeight;

  /// 非当前行视觉缩放（仅变换，不影响行高；默认 1.0）。
  final double inactiveScale;

  /// 非当前行透明度（默认 0.55，乘在颜色上）。
  final double unplayedAlpha;

  /// 文本对齐（默认居中；Vutron 布局左对齐）。
  final TextAlign textAlign;

  /// 上下渐隐（直接乘进每行颜色，零离屏层）。
  final bool fadeEdges;

  /// 行高默认值（含间距）。
  static const double defaultLineHeight = 44;

  @override
  State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView>
    with SingleTickerProviderStateMixin {
  /// 整个歌词视口的滚动偏移（逻辑像素）。无界，由目标值夹到 [0, maxScroll]。
  late final AnimationController _scroll;

  /// 当前布局（行高 / 累计 top / 总高）；宽度 / 样式 / 当前行变化时重算。
  _LyricsLayout? _layout;
  Object? _layoutKey;

  /// 上一次用于「是否动画」判断的样式键（不含当前行索引）。
  Object? _lastBaseKey;

  /// 上一次已调度跟随的当前行索引。
  int _lastFollowIndex = -2;

  /// 当前目标偏移（手动浏览恢复时复用）。
  double _target = 0;

  /// 手动浏览（滚轮 / 拖拽）期间冻结自动跟随；3 秒后恢复。
  Timer? _resumeTimer;
  bool _userScrolling = false;

  /// 首帧直接吸附到目标，不做入场滚动。
  bool _didInitialSnap = false;

  /// 行高实测缓存（有界 LRU）：位置 tick 不改变行高，命中即跳过排版。
  final _rowHeightCache = <_LyricsRowHeightKey, double>{};

  // ---- 测试探针（仅统计用，不参与运行逻辑）----
  int _builtLines = 0;
  int _measuredLines = 0;
  int _lastWindowSize = 0;

  @visibleForTesting
  int debugBuiltLines() => _builtLines;

  @visibleForTesting
  int debugMeasuredLines() => _measuredLines;

  @visibleForTesting
  int debugLastWindowSize() => _lastWindowSize;

  @override
  void initState() {
    super.initState();
    _scroll = AnimationController.unbounded(vsync: this, value: 0);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 主题颜色 / 文本缩放 / 默认字体样式可能已变：布局与实例缓存作废。
    _layoutKey = null;
    _lastBaseKey = null;
    _rowHeightCache.clear();
  }

  @override
  void didUpdateWidget(LyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.groups, widget.groups)) {
      _layoutKey = null;
      _lastBaseKey = null;
      _lastFollowIndex = -2;
      _didInitialSnap = false;
      _rowHeightCache.clear();
    }
  }

  @override
  void dispose() {
    _resumeTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _buildLyricsView(context);
}
