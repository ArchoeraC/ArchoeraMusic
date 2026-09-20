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
///   （blur）+ 透明度**景深（失焦默认走「整层一次 + 1/4 重采样」，见
///   [LyricsBlurMode]），激活行用「羽化遮罩扫亮 + 逐词上浮/长音强调」，
///   翻译小字随主行；点击 seek、拖拽浏览松手回弹、可隐藏已唱行。
/// 纯 Dart/Flutter，无第三方依赖、无 FFI。
library;

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding, Ticker;

import '../../../services/lyrics/lyric_line.dart';
import 'interlude_dots.dart';
import 'lyric_clock.dart';
import 'lyrics_blur_budget.dart';
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
///
/// ⚠ AMLL 的 `filter: blur(Xpx)` 里 X 就是**高斯 σ**（CSS Filter Effects 规范：
/// blur() 的参数「defines the value of the standard deviation」），所以逐行档的
/// σ 直接取本值（2~5），不再额外折半。
const double kMaxBlurPx = 5.0;

/// 非激活行失焦的实现档位：观感目标相同，成本差一个量级。
enum LyricsBlurMode {
  /// 整层一次失焦（**默认**）：所有非激活行画进同一个离屏层，一次高斯，
  /// 且在 1/4 尺寸上做（[kPanelBlurDownsample]）。
  ///
  /// 层数恒定、与可见行数无关；半径统一为 [kPanelBlurSigma]，不区分距离
  /// （AMLL 是每行独立 σ 2~5，这里取中值近似——刻意差异，见
  /// docs/lyrics-amll-alignment.md §3.10）。
  panel,

  /// 逐行 bounded 失焦：最贴 AMLL（每行独立 σ = `min(5, 1+距离)`），
  /// 但每帧离屏层数 ≈ 可见行数，弱机/软件光栅上会直接爆帧
  /// （基准见 docs/player-render-optimization.md §4.2）。可用环境变量
  /// [lyricsBlurOverride] 在真机上切换对比。
  perLine,

  /// 不失焦（只剩透明度景深）。
  off,
}

/// 用户可选的失焦档位（设置项 `amll.blurQuality`，默认 [auto]）。
///
/// 与 [LyricsBlurMode] 的区别：这里是**用户意图**（要不要省、要不要贴上游），
/// 由 [resolveLyricsBlurMode] 映射到实际画法；显式选择时不做自动降级
/// ——决定权在用户手里。
enum LyricsBlurQuality {
  /// 自动（默认）：整层档起步；若这台机器持续掉帧，守卫自动关掉失焦（只降不升）。
  auto('auto'),

  /// 流畅优先：固定整层档（1 个离屏层 + 1/4 重采样），不自动降级。
  fast('fast'),

  /// 画质优先：固定逐行档（σ = `min(5, 1+距离)`，最贴 AMLL 的半径梯度），最吃 GPU。
  quality('quality'),

  /// 关闭失焦（只剩透明度景深）。
  off('off');

  const LyricsBlurQuality(this.key);

  /// 持久化键（`amll.blurQuality` 的取值）。
  final String key;

  /// 解析持久化值；未知/空 → [auto]。
  static LyricsBlurQuality parse(String? raw) {
    for (final q in values) {
      if (q.key == raw) return q;
    }
    return LyricsBlurQuality.auto;
  }
}

/// 整层失焦的等效高斯 σ（AMLL 每行 σ 为 `min(5, 1+距离)` = 2~5，取中值）。
const double kPanelBlurSigma = 3.0;

/// 整层失焦的降采样倍率：模糊在 1/4 尺寸上做（模糊像素量 1/4），再放大回原尺寸。
///
/// 非激活行本来就是模糊的，重采样几乎看不出差别；这是「保留观感、砍掉成本」
/// 的关键一步（同一场景基准：整层 1/1 = 39.4ms，1/4 = 16.2ms）。
const double kPanelBlurDownsample = 0.25;

/// 诊断用环境变量：`ARCHOERA_LYRICS_BLUR=perline|panel|off`。
///
/// 与 `ARCHOERA_FLUID_SHADER` / `ARCHOERA_RIPPLE_SHADER` 同一套做法：不改代码、
/// 不重编译就能在真机上 A/B 失焦档位。显式指定时**不做自动降级**（便于对比）。
/// 解析失败返回 null（= 用默认档位）。
LyricsBlurMode? lyricsBlurOverrideFrom(String? raw) {
  switch (raw?.trim().toLowerCase()) {
    case 'perline':
    case 'per-line':
    case 'per_line':
      return LyricsBlurMode.perLine;
    case 'panel':
      return LyricsBlurMode.panel;
    case 'off':
    case 'none':
    case '0':
      return LyricsBlurMode.off;
    default:
      return null;
  }
}

/// 进程启动时的环境变量覆盖（只读一次；见 [lyricsBlurOverrideFrom]）。
final LyricsBlurMode? lyricsBlurOverride =
    lyricsBlurOverrideFrom(Platform.environment['ARCHOERA_LYRICS_BLUR']);

/// 解析最终生效的失焦画法。
///
/// 优先级：诊断用环境变量 > 用户档位。只有 [LyricsBlurQuality.auto] 会吃
/// 自动降级；用户显式选了 `fast`/`quality` 就照他选的来（决定权交给用户）。
LyricsBlurMode resolveLyricsBlurMode({
  required LyricsBlurQuality quality,
  LyricsBlurMode? override,
  required bool autoDegraded,
}) {
  if (override != null) return override;
  switch (quality) {
    case LyricsBlurQuality.off:
      return LyricsBlurMode.off;
    case LyricsBlurQuality.fast:
      return LyricsBlurMode.panel;
    case LyricsBlurQuality.quality:
      return LyricsBlurMode.perLine;
    case LyricsBlurQuality.auto:
      return autoDegraded ? LyricsBlurMode.off : LyricsBlurMode.panel;
  }
}

/// 视口窗口上下余量：取「视口高度 × [kViewportWindowMarginRatio]」与
/// [kViewportWindowMarginMinPx] 的较大者。
///
/// 不写死像素：全屏/4K 需要更大的余量，小窗口不该把整首歌都算进窗口。
const double kViewportWindowMarginRatio = 0.6;

/// 视口窗口余量下限（逻辑像素）。
const double kViewportWindowMarginMinPx = 180.0;

/// 「高速换行」判定：相邻两行间隔 ≤ 该值（毫秒）时，等弹簧安顿已来不及，
/// 直接吸附成普通滚动（观感对齐 AMLL 高速换行段）。
///
/// 判定刻意收紧（见 `_maybeRetarget`）：仅在「非 seek + 只推进一行 +
/// 间隔 ≤ 本值 + 位移约等于一行」时生效，正常速度的换行仍然走弹簧。
const int kFastLineChangeMs = 250;

/// 高速换行判定的位移上限（视口高度比例）：超过就按跨屏跳转处理。
const double kFastLineChangeMaxShiftRatio = 0.4;

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
    this.blurQuality = LyricsBlurQuality.auto,
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

  /// 非激活行失焦档位（默认 [LyricsBlurQuality.auto]；见 [LyricsBlurMode]）。
  final LyricsBlurQuality blurQuality;

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
  List<double> blur = const []; // 每行失焦等级（px = AMLL blur 参数 = 高斯 σ）
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

  /// 生效的失焦档位（见 [LyricsBlurMode]）：已含关闭开关、环境变量覆盖
  /// 与帧预算自动降级。
  LyricsBlurMode blurMode = LyricsBlurMode.panel;

  /// 整层失焦强度 0~1（悬停/失焦开关切换时由状态层平滑到 0，避免「啪」地变换）。
  double panelBlur = 0;
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
