// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// AMLL v7 物理歌词墙（物理歌词引擎的 Flutter 版）。
///
/// - 布局：每行高度由 [computeLineHeights] 实测（主行+翻译，长行自动换行、
///   多行计入行高），[computeCenters] 累计自然中心；
/// - 定位：布局锚点（anchor）中心锚定 `align*viewH`，其余行按自然中心平移；
///   每行独立 [Spring1D]（默认 0.9/15/90，轻微过冲）。换行时按距锚点
///   距离设置延迟（级联），速度继承连续；首次/seek/跨屏跳转对所有行
///   同步下发目标（无级联），保证整墙一起位移、行距不塌陷。
/// - 锚点与高亮分离：无行覆盖播放位置（前奏/间奏空隙/末尾）时保持上一个
///   锚点，绝不回退到首行；仅当 seek 跨出歌词范围才定位到最近边界行。
/// - 时钟：把 ~20Hz 的播放位置事件经 [LyricClock] 插值到 vsync，逐字扫亮
///   与滚动因此是平滑的（对齐 AMLL 的 rAF 驱动）。
/// - 绘制：CustomPainter 可见行裁剪；非激活行按距离做**弹簧缩放 + 高斯失焦
///   （blur）+ 透明度**景深，激活行用「羽化遮罩扫亮 + 逐词上浮/长音强调」，
///   翻译小字随主行；点击 seek、拖拽浏览松手回弹、可隐藏已唱行。
/// 纯 Dart/Flutter，无第三方依赖、无 FFI。
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/scheduler.dart' show Ticker;

import '../../../services/lyrics/lyric_line.dart';
import 'interlude_dots.dart';
import 'lyric_clock.dart';
import 'lyrics_fragment_render.dart';
import 'lyrics_layout.dart';
import 'lyrics_paragraph_cache.dart';
import 'lyrics_word_anim.dart';
import 'spring.dart';
import 'spring_policy.dart';
import 'package:archoera_music/eta/icon/eta_icons.dart';

part 'lyrics_physics_wall/lyrics_physics_wall_state.dart';
part 'lyrics_physics_wall/lyrics_physics_wall_painter.dart';

/// 级联延迟步长（毫秒/距离）。
const double kCascadeStepMs = 50; // 与上游 AMLL 的 0.05s base 级联一致

/// 非激活行最大失焦半径（逻辑像素，对应 AMLL `blur(1+distance)` 的 5px 上限）。
const double kMaxBlurPx = 5.0;

/// 失焦只作用于距锚点不超过该行数的行。
///
/// 更远的行本来就只剩透明度层次，再为它们每帧开离屏高斯层（`saveLayer` +
/// `ImageFilter.blur`）性价比极低——这是歌词区最主要的 raster 开销来源之一。
const int kMaxBlurDistance = 2;

/// 视口窗口上下余量：取「视口高度 × [kViewportWindowMarginRatio]」与
/// [kViewportWindowMarginMinPx] 的较大者。
///
/// 不写死像素：全屏/4K 需要更大的余量，小窗口不该把整首歌都算进窗口。
const double kViewportWindowMarginRatio = 0.6;

/// 视口窗口余量下限（逻辑像素）。
const double kViewportWindowMarginMinPx = 180.0;

/// 激活行「点亮」过渡时间常数（秒）：0→1 用 [kActivateTauIn]，1→0 用
/// [kActivateTauOut]（对齐 AMLL `--mask-alpha-duration` 的 .3s / .45s）。
const double kActivateTauIn = 0.09;
const double kActivateTauOut = 0.15;

/// 「default」预设 = **AMLL 自适应弹簧策略**（按行间隔动态调整，见
/// `spring_policy.dart`），而不是一套固定参数。用户可在设置里换成
/// 下面其它固定手感。
const String kDefaultSpringPreset = 'default';

/// 固定弹簧预设 → (mass, damping, stiffness)。
///
/// 注意：`default` 不在此表中（走自适应策略）。这些预设按阻尼比从柔和到
/// 硬朗排列，供用户手动覆盖 AMLL 手感。
const Map<String, SpringParams> kSpringPresets = {
  'smooth': SpringParams(mass: 1.2, damping: 22, stiffness: 80),
  'responsive': SpringParams(mass: 0.5, damping: 18, stiffness: 150),
  'jello': SpringParams(mass: 0.6, damping: 8, stiffness: 120), // ζ≈0.47
  'heavy': SpringParams(mass: 2.0, damping: 25, stiffness: 60),
};

class AmllPhysicsWall extends StatefulWidget {
  const AmllPhysicsWall({
    super.key,
    required this.groups,
    required this.positionMs,
    required this.onSeek,
    this.playing = false,
    this.fontSize = 18,
    this.fontFamily,
    this.fontWeight = FontWeight.w600,
    this.playedColor = const Color(0xFFD0D3DA),
    this.unplayedColor = const Color(0xFF9AA1B5),
    this.showTranslation = true,
    this.showRomanization = false,
    this.alignFraction = 0.5,
    this.inactiveAlpha = 0.45,
    this.wordSweep = true,
    this.hidePassed = false,
    this.enableScale = true,
    this.enableBlur = true,
    this.wordFadeWidth = 0.5,
    this.springPreset = 'default',
    this.animate = true,
  });

  final List<LyricGroup> groups;
  final int positionMs;
  final ValueChanged<int> onSeek;

  /// 是否正在播放。为 true 且 [animate] 时，内部时钟按 vsync 外推，
  /// 逐字扫亮/滚动平滑；暂停时严格等于 [positionMs]。
  final bool playing;

  final double fontSize;
  final String? fontFamily;

  /// 激活行字重（对齐设置里的歌词字重；非激活行固定 w400）。
  final FontWeight fontWeight;

  final Color playedColor;
  final Color unplayedColor;
  final bool showTranslation;

  /// 显示音译（罗马音）小字（主行下方、译文之上）。
  final bool showRomanization;

  final double alignFraction;
  final double inactiveAlpha;
  final bool wordSweep;
  final bool hidePassed;

  /// 非激活行缩放（激活 1.0 / 非激活 0.97，弹簧平滑）。
  final bool enableScale;

  /// 非激活行高斯失焦（按距离 1~5px）。
  final bool enableBlur;

  /// 扫亮羽化带宽度（× 字号，对齐 AMLL `wordFadeWidth`）。
  final double wordFadeWidth;

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
  List<double> scale = const []; // 每行当前缩放（非激活 → 0.97）
  List<double> fade = const []; // 每行激活外观权重 0（未激活）~1（激活）
  List<double> blur = const []; // 每行失焦 sigma（px）
  double w = 0;
  double h = 0;
  double align = 0.5;
  double fontSize = 18;
  String? fontFamily;
  double inactiveAlpha = 0.45;
  bool wordSweep = true;
  bool hidePassed = false;
  bool showTranslation = true;
  bool showRomanization = false;
  FontWeight fontWeight = FontWeight.w600;
  bool enableScale = true;
  bool enableBlur = true;
  double wordFadeWidth = 0.5;
  Color played = const Color(0xFFD0D3DA);
  Color unplayed = const Color(0xFF9AA1B5);

  /// 当前布局锚点（间奏/无覆盖时用于景深与透明度的「焦点」）。
  int anchor = -1;

  /// 间奏三点动画的当帧状态。
  InterludeDotsState dots = InterludeDotsState.hidden;

  /// 间奏三点在自然坐标系中的中心 y。
  double dotsNaturalY = 0;

  /// 已排版段落缓存（可见窗口，P1）。见 [LyricsParagraphCache]。
  final LyricsParagraphCache cache = LyricsParagraphCache();

  /// 激活行的逐字渲染缓存（逐字盒 + 逐字段落）。见 [LyricsFragmentCache]。
  final LyricsFragmentCache fragCache = LyricsFragmentCache();
}
