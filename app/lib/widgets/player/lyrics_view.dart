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
/// 观感对齐 SPlayer-Next `lyric-dom` 的普通歌词档位（不引入额外特效）：
/// - 非当前行透明度更低，当前行与周边的层级更明确；
/// - 行激活 / 失活时颜色、字重、缩放都走同一段缓动，不再瞬切；
/// - 逐字扫亮按片段时长连续插值（含 80ms 预滚与渐变过渡）；
/// - 滚动提前 [kLyricsScrollPrerollMs] 启动，开唱时当前行已经就位。
///
/// 样式参数（字号 / 行高 / 已唱色 / 未唱色）由播放页从「设置 → 歌词」
/// 偏好传入（对齐原版 desktopLyric 的个性化配置）。
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:material_ui/material_ui.dart';

import '../../services/lyrics/lyric_line.dart';
import 'lyrics_v7/lyrics_layout.dart';
import '../../l10n/l10n.dart';
import '../common/anim.dart';
import '../common/smooth_wheel_scroll_controller.dart';
import 'lyrics_edge_fade.dart';
import 'lyrics_view/lyrics_balance.dart';

part 'lyrics_view/lyrics_karaoke.dart';
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
    this.unplayedAlpha = 0.35,
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

  /// 当前行字号（null = [fontSize] × [kActiveLineFontScale]）。
  ///
  /// Vutron 经典布局当前行与普通行同字号（视觉缩放由 [inactiveScale] 表达）。
  final double? currentFontSize;

  /// 非当前行字重（默认 w400；Vutron 布局用 w600）。
  final FontWeight inactiveFontWeight;

  /// 非当前行视觉缩放（仅变换，不影响行高；默认 1.0）。
  final double inactiveScale;

  /// 非当前行透明度（默认 0.35，乘在颜色上；对齐 SPlayer `inactiveAlpha`）。
  final double unplayedAlpha;

  /// 文本对齐（默认居中；Vutron 布局左对齐）。
  final TextAlign textAlign;

  /// 上下 25% 渐隐遮罩（Vutron 的 `mask:true` 观感）。
  final bool fadeEdges;

  /// 行高默认值（含间距）。
  static const double defaultLineHeight = 44;

  @override
  State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView> {
  /// 滚轮 / 触控板使用与列表、AMLL 歌词墙相同的弹簧手感。
  final _controller = SmoothWheelScrollController();

  /// 已滚动到的目标行索引（避免每帧滚动）。
  ///
  /// 与「当前高亮行」不同：滚动会提前 [kLyricsScrollPrerollMs] 启动，
  /// 让下一行在开唱前就滑到视口中心（对齐 `lyric-dom` 的滚动预滚）。
  int _scrollIndex = -1;

  /// 当前滚动目标偏移（用户手动浏览期间也会持续更新，供恢复跟随时使用）。
  double? _followOffset;

  /// 用户正在手动滚轮 / 拖拽浏览歌词。
  ///
  /// 期间冻结自动跟随，避免用户刚滚上去就被播放进度拽回当前行；
  /// 停止操作 [_kUserScrollResumeDelay] 后平滑回到当前行。
  bool _userScrolling = false;
  Timer? _resumeTimer;

  /// 平衡换行结果（按行索引；仅文本 / 宽度 / 样式变化时重算）。
  List<BalancedLyric>? _balanced;
  Object? _balanceKey;

  /// 实测行高缓存（有界 LRU）。50ms 位置 tick / 滚动 / 主题稳定时，
  /// 绝大多数行的文本与样式未变，直接命中原高度即可跳过重复的
  /// TextPainter 布局（每次 build 原本对全部行跑一遍 = O(行数)）。
  /// 宽度 / 字号 / 文本缩放 / 默认字体样式变化时键失配自然失效。
  final _rowHeightCache = <_LyricsRowHeightKey, double>{};

  /// 行高列表（按需重算；见 [_heightsKey]）。
  ///
  /// 位置 tick（~20Hz）不改变任何行高——只有「当前行翻转 / 分组 / 宽度 /
  /// 样式」变化才需要重算（换行约每几秒一次），避免每 tick 跑 O(行数)。
  List<double>? _heights;
  Object? _heightsKey;

  /// 非当前行 widget 实例缓存。
  ///
  /// 返回**同一实例**时 Flutter 的 `Element.updateChild` 会直接跳过该子树的
  /// 重建与重绘（identical widget 短路）；当前行因逐字扫亮每 tick 变化，
  /// 不入缓存。缓存随当前行翻转 / 配置 / 主题变化整体作废。
  final _lineCache = <int, Widget>{};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 主题（颜色）/ 文本缩放 / 默认字体样式可能已变：缓存实例与行高作废。
    _lineCache.clear();
    _heightsKey = null;
    _balanceKey = null;
  }

  @override
  void didUpdateWidget(LyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换歌 / 换歌词：滚动目标必须重新解析，否则新歌词会停在旧索引。
    if (!identical(oldWidget.groups, widget.groups)) {
      _scrollIndex = -1;
      _lineCache.clear();
      _heightsKey = null;
      _balanceKey = null;
      // 新歌词直接吸附，不做跨越整首歌的滚动动画。
      _followOffset = null;
      return;
    }
    // 颜色 / 对齐 / 非当前行缩放与透明度不影响行高，但会改变
    // 已缓存的非当前行实例：这些键不在 heightsKey 里，需单独作废。
    if (oldWidget.playedColor != widget.playedColor ||
        oldWidget.unplayedColor != widget.unplayedColor ||
        oldWidget.textAlign != widget.textAlign ||
        oldWidget.inactiveScale != widget.inactiveScale ||
        oldWidget.unplayedAlpha != widget.unplayedAlpha) {
      _lineCache.clear();
    }
  }

  @override
  void dispose() {
    _resumeTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _buildLyricsView(context);

  /// 按实测行高算出的目标偏移滚动（长行换行后行高可变，不能再按
  /// 「索引 × 固定行高」换算；偏移由 [_LyricsViewBuild._offsetFor] 给出）。
  void _scrollToOffset(double offset) {
    if (_userScrolling) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _userScrolling || !_controller.hasClients) return;
      final max = _controller.position.maxScrollExtent;
      _controller.animateTo(
        offset.clamp(0.0, max),
        duration: animDuration(context, const Duration(milliseconds: 280)),
        curve: Curves.easeOutCubic,
      );
    });
  }

  /// 用户开始手动浏览（滚轮 / 拖拽）：先冻结自动跟随。
  void _beginUserScroll() {
    _userScrolling = true;
    _resumeTimer?.cancel();
  }

  /// 用户停止浏览：延迟 [_kUserScrollResumeDelay] 后回到当前行。
  ///
  /// 连续滚动期间每收到一次结束通知都会重置计时，避免滚一下就被拽回去。
  void _endUserScroll() {
    if (!_userScrolling) return;
    _resumeTimer?.cancel();
    _resumeTimer = Timer(_kUserScrollResumeDelay, () {
      if (!mounted) return;
      _userScrolling = false;
      final target = _followOffset;
      if (target != null) _scrollToOffset(target);
    });
  }
}

/// 用户手动浏览歌词后，恢复自动跟随的延迟。
const Duration _kUserScrollResumeDelay = Duration(seconds: 3);
