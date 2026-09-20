// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 歌词 v7 可变行高布局工具：行高实测 + 自然中心累计。
///
/// 对齐 AMLL：每组主歌词在可用宽度内**自动换行**（不再单行省略号截断），
/// 开启翻译且该组带翻译时，再在主行下方叠一行小字号译文（同样可换行）
/// 并计入行高；由各组的自然高度推得每行的自然中心
/// （中心间距 = 前后半高 + 行间隙）。
///
/// 纯 Dart/Flutter，仅依赖 [TextPainter]，不依赖 Riverpod 等状态库。
library;

import 'dart:math' as math;

import 'package:flutter/painting.dart';

import '../../../services/lyrics/lyric_line.dart';

/// 主行与翻译之间的间距（按主字号比例）——**简单引擎 `LyricsView` 专用**。
const double kMainTranslationGapEm = 0.05; // 主↔译 0.05×

/// 翻译小字字号相对主字号的倍率（0.6）——**简单引擎 `LyricsView` 专用**。
const double kTranslationFontScale = 0.6;

/// ── v7 AMLL 引擎的排版度量（对齐 AMLL `lyric-player.module.css`）──────

/// 主行行高倍率（CSS `line-height: 1.2`）。
const double kLyricLineHeightEm = 1.2;

/// 相邻两行之间的间隙（AMLL `.lyricLineWrapper` 上下各 `padding: .4em`）。
const double kLyricLineGapEm = 0.8;

/// 主行与翻译之间的间隙（AMLL wrapper 的 `gap: .3em`）。
const double kLyricTranslationGapEm = 0.3;

/// 翻译字号倍率（AMLL `.lyricSubLine`：`max(.5em, 10px)`）。
const double kLyricTranslationFontScale = 0.5;

/// 翻译字号下限（px）。
const double kLyricTranslationMinPx = 10;

/// 翻译行高倍率（AMLL `.lyricSubLine`：`line-height: 1.5em`）。
const double kLyricTranslationLineHeightEm = 1.5;

/// 翻译字号（px）：`max(.5em, 10px)`。
double lyricTranslationFontSize(double fontSize) =>
    math.max(kLyricTranslationMinPx, fontSize * kLyricTranslationFontScale);

/// 翻译小字是否计入行高的开关默认值。
const bool kDefaultShowTranslation = true;

/// 背景人声行字号相对主行的倍率（对齐 AMLL `--amll-lp-bg-line-scale` 0.7）。
const double kBgFontScale = 0.7;

/// 相邻两行中心之间的默认间隙（逻辑像素）。
const double kDefaultGapPx = 8;

/// 按组实测每行高度（逻辑像素）。
///
/// 单组行高 = 主行原文 [TextPainter] 实测高；若 [showRomanization] 且该组
/// 带音译，再加一行小字号音译；若 [showTranslation] 且该组带翻译，再加
/// 一行小字号译文（绘制顺序与 painter 一致：音译在上、译文在下）。
/// 文本按 [fontSize] / [fontFamily] / [fontWeight] 在 [maxWidth] 内排版，
/// [TextPainter] 统一使用 `textDirection: TextDirection.ltr`。
///
/// ⚠ 这是「全量测量」：会为**每一行**排一次版。视口化之后引擎只用它做
/// 测试/兜底，运行时请用 [computeLineHeight]（按需）+
/// [estimateLineHeight]（未测量的远行估算）。
List<double> computeLineHeights(
  List<LyricGroup> groups, {
  required double fontSize,
  String? fontFamily,
  required double maxWidth,
  bool showTranslation = kDefaultShowTranslation,
  bool showRomanization = false,
  FontWeight fontWeight = FontWeight.w600,
}) {
  return [
    for (final g in groups)
      computeLineHeight(
        g,
        fontSize: fontSize,
        fontFamily: fontFamily,
        maxWidth: maxWidth,
        showTranslation: showTranslation,
        showRomanization: showRomanization,
        fontWeight: fontWeight,
      ),
  ];
}

/// 单组行高实测（按需测量用，度量与 [computeLineHeights] 完全一致）。
double computeLineHeight(
  LyricGroup g, {
  required double fontSize,
  String? fontFamily,
  required double maxWidth,
  bool showTranslation = kDefaultShowTranslation,
  bool showRomanization = false,
  FontWeight fontWeight = FontWeight.w600,
}) {
  return _measureGroup(
    g,
    fontSize,
    fontFamily,
    maxWidth,
    showTranslation,
    showRomanization,
    fontWeight,
  );
}

/// 未测量行的**估算**行高（不做排版）。
///
/// 视口之外的行不值得为几行可见歌词就整首排版：先用估算值参与中心计算，
/// 等该行进入视口再用 [computeLineHeight] 实测替换（AMLL 的
/// `LayoutCalculator` 也是这么做的：未测量行用 `defaultLineHeight` 兜底）。
double estimateLineHeight(
  LyricGroup g, {
  required double fontSize,
  bool showTranslation = kDefaultShowTranslation,
  bool showRomanization = false,
}) {
  var h = fontSize * kLyricLineHeightEm;
  if (g.isBG) return h * kBgFontScale;
  final subFs = lyricTranslationFontSize(fontSize);
  final subH = fontSize * kLyricTranslationGapEm +
      subFs * kLyricTranslationLineHeightEm;
  if (showRomanization && (g.romaji?.isNotEmpty ?? false)) h += subH;
  if (showTranslation && (g.translation?.isNotEmpty ?? false)) h += subH;
  return h;
}

double _measureGroup(
  LyricGroup g,
  double fontSize,
  String? fontFamily,
  double maxWidth,
  bool showTranslation,
  bool showRomanization,
  FontWeight fontWeight,
) {
  // 背景人声行字号更小（对齐 AMLL `--amll-lp-bg-line-scale`）。
  final mainFs = g.isBG ? fontSize * kBgFontScale : fontSize;
  // 主行按激活态字重保守测量：长行换行后的行数不会因激活加粗
  // 而变多导致溢出；非激活行即使略窄也只会多留一点行距。
  var h = _textHeight(
    g.original.text,
    mainFs,
    fontFamily,
    maxWidth,
    fontWeight: fontWeight,
    lineHeightEm: kLyricLineHeightEm,
  );
  final subFs = lyricTranslationFontSize(fontSize);
  // 音译（罗马音）在主行下方、翻译之上（与 painter 的绘制顺序一致）。
  if (!g.isBG && showRomanization && (g.romaji?.isNotEmpty ?? false)) {
    h +=
        fontSize * kLyricTranslationGapEm +
        _textHeight(
          g.romaji!,
          subFs,
          fontFamily,
          maxWidth,
          lineHeightEm: kLyricTranslationLineHeightEm,
        );
  }
  if (!g.isBG && showTranslation && (g.translation?.isNotEmpty ?? false)) {
    h +=
        fontSize * kLyricTranslationGapEm +
        _textHeight(
          g.translation!,
          subFs,
          fontFamily,
          maxWidth,
          lineHeightEm: kLyricTranslationLineHeightEm,
        );
  }
  return h;
}

/// 单段文本排版实测高。TextPainter 按约定传入 [fontFamily]（可为 null，
/// 走默认字体）与 ltr 方向；超过 [maxWidth] 时自动换行，返回多行总高。
///
/// [lineHeightEm] 必须与绘制端（`ui.ParagraphStyle` / `ui.TextStyle` 的
/// `height`）一致，否则行高会与实际渲染不符。
double _textHeight(
  String text,
  double fs,
  String? fontFamily,
  double maxWidth, {
  FontWeight fontWeight = FontWeight.w400,
  double lineHeightEm = kLyricLineHeightEm,
}) {
  final tp = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        fontFamily: fontFamily,
        fontSize: fs,
        fontWeight: fontWeight,
        height: lineHeightEm,
      ),
    ),
    textDirection: TextDirection.ltr,
    textAlign: TextAlign.center,
  )..layout(maxWidth: maxWidth);
  return tp.height;
}

/// 由行高列表推每行中心（自然中心）的累计纵坐标。
///
/// 第一行中心在自身半高处；后续行中心 = 前一行中心 + 前一行半高 +
/// [gapPx] + 本行半高。空列表返回空列表。
///
/// [isBg] 标记背景人声行：背景人声**不占独立纵向槽位**，挂在最近一个
/// 主行下方（间距为 [gapPx] × 0.4），因此主行滚动时背景行同步跟随
/// （对齐 AMLL 的 bg line 与主行同组）。
List<double> computeCenters(
  List<double> heights, {
  double gapPx = kDefaultGapPx,
  List<bool>? isBg,
}) {
  if (heights.isEmpty) return const [];
  final centers = <double>[];
  int? lastMain;
  for (var i = 0; i < heights.length; i++) {
    final bg = isBg != null && i < isBg.length && isBg[i];
    if (bg && lastMain != null) {
      centers.add(
        centers[lastMain] +
            heights[lastMain] / 2 +
            gapPx * 0.4 +
            heights[i] / 2,
      );
      continue;
    }
    if (lastMain == null) {
      centers.add(heights[i] / 2);
    } else {
      centers.add(
        centers[lastMain] + heights[lastMain] / 2 + gapPx + heights[i] / 2,
      );
    }
    lastMain = i;
  }
  return centers;
}
