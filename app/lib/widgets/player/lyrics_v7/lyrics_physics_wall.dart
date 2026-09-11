// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// AMLL v7 物理歌词墙：忠实移植 SPlayer-Next 自研物理歌词引擎的 Flutter 版。
///
/// - 布局：每行高度由 [computeLineHeights] 实测（主行+翻译，长行自动换行、
///   多行计入行高），[computeCenters] 累计自然中心；
/// - 定位：布局锚点（anchor）中心锚定 `align*viewH`，其余行按自然中心平移；
///   每行独立 [Spring1D]（默认 0.9/15/90，轻微过冲）。换行时按距锚点
///   距离设置延迟（级联），速度继承连续；首次/seek/跨屏跳转对所有行
///   同步下发目标（无级联），保证整墙一起位移、行距不塌陷。
/// - 锚点与高亮分离：无行覆盖播放位置（前奏/间奏空隙/末尾）时保持上一个
///   锚点，绝不回退到首行；仅当 seek 跨出歌词范围才定位到最近边界行。
/// - 绘制：CustomPainter 可见行裁剪，距离渐淡/缩放、逐字渐变、翻译小字、
///   上下边缘渐隐；点击 seek、拖拽浏览松手回弹、可隐藏已唱行。
/// 纯 Dart/Flutter，无第三方依赖、无 FFI。
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;

import '../../../services/lyrics/lyric_line.dart';
import 'lyrics_layout.dart';
import 'lyrics_paragraph_cache.dart';
import 'spring.dart';
import 'package:archoera_music/eta/icon/eta_icons.dart';

part 'lyrics_physics_wall/lyrics_physics_wall_state.dart';
part 'lyrics_physics_wall/lyrics_physics_wall_painter.dart';

/// 级联延迟步长（毫秒/距离）。
const double kCascadeStepMs = 50; // 每行滞后更强（对齐 SPlayer 的 50ms base 级联观感）

/// 弹簧预设 → (mass, damping, stiffness)。
const Map<String, SpringParams> kSpringPresets = {
  'default': SpringParams(
    mass: 0.85,
    damping: 11,
    stiffness: 160,
  ), // ζ≈0.47，过冲更明显
  'smooth': SpringParams(mass: 1.2, damping: 22, stiffness: 80),
  'responsive': SpringParams(mass: 0.5, damping: 18, stiffness: 150),
  'jello': SpringParams(mass: 0.6, damping: 8, stiffness: 120),
  'heavy': SpringParams(mass: 2.0, damping: 25, stiffness: 60),
};

class AmllPhysicsWall extends StatefulWidget {
  const AmllPhysicsWall({
    super.key,
    required this.groups,
    required this.positionMs,
    required this.onSeek,
    this.fontSize = 18,
    this.fontFamily,
    this.playedColor = const Color(0xFF4DA3FF),
    this.unplayedColor = const Color(0xFF9AA1B5),
    this.showTranslation = true,
    this.alignFraction = 0.5,
    this.inactiveAlpha = 0.45,
    this.wordSweep = true,
    this.hidePassed = false,
    this.springPreset = 'default',
    this.animate = true,
  });

  final List<LyricGroup> groups;
  final int positionMs;
  final ValueChanged<int> onSeek;
  final double fontSize;
  final String? fontFamily;
  final Color playedColor;
  final Color unplayedColor;
  final bool showTranslation;
  final double alignFraction;
  final double inactiveAlpha;
  final bool wordSweep;
  final bool hidePassed;
  final String springPreset;
  final bool animate;

  @override
  State<AmllPhysicsWall> createState() => _AmllPhysicsWallState();
}

class _PaintCtx {
  List<LyricGroup> groups = const [];
  int positionMs = 0;
  int active = -1;
  List<double> heights = const [];
  List<double> centers = const [];
  List<double> y = const []; // 每行当前屏幕中心
  List<double> scale = const [];
  double w = 0;
  double h = 0;
  double align = 0.5;
  double fontSize = 18;
  String? fontFamily;
  double inactiveAlpha = 0.45;
  bool wordSweep = true;
  bool hidePassed = false;
  bool showTranslation = true;
  Color played = const Color(0xFF4DA3FF);
  Color unplayed = const Color(0xFF9AA1B5);
  double drag = 0;

  /// 已排版段落缓存（可见窗口，P1）。见 [LyricsParagraphCache]。
  final LyricsParagraphCache cache = LyricsParagraphCache();
}
