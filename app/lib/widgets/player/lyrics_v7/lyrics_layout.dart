/// 歌词 v7 可变行高布局工具：行高实测 + 自然中心累计。
///
/// 口径与 amll_wall_v5 一致：每组一行主歌词（单行，过长省略号截断），
/// 开启翻译且该组带翻译时，再在主行下方叠一行小字号译文并计入行高；
/// 由各组的自然高度推得每行的自然中心（中心间距 = 前后半高 + 行间隙）。
///
/// 纯 Dart/Flutter，仅依赖 [TextPainter]，不依赖 Riverpod 等状态库。
library;

import 'package:flutter/painting.dart';

import '../../../services/lyrics/lyric_line.dart';

/// 主行与翻译之间的间距（按主字号比例）。
const double kMainTranslationGapEm = 0.05; // 主↔译 0.05×

/// 翻译小字字号相对主字号的倍率（0.6）。
const double kTranslationFontScale = 0.6;

/// 翻译小字是否计入行高的开关默认值。
const bool kDefaultShowTranslation = true;

/// 相邻两行中心之间的默认间隙（逻辑像素）。
const double kDefaultGapPx = 8;

/// 按组实测每行高度（逻辑像素）。
///
/// 单组行高 = 主行原文 [TextPainter] 实测高；若 [showTranslation] 且该组
/// 带翻译，再加主行与译文间距 + 小字号译文实测高。文本按 [fontSize] /
/// [fontFamily] 在 [maxWidth] 内单行排版（过长省略号截断），
/// [TextPainter] 统一使用 `textDirection: TextDirection.ltr`。
List<double> computeLineHeights(
  List<LyricGroup> groups, {
  required double fontSize,
  String? fontFamily,
  required double maxWidth,
  bool showTranslation = kDefaultShowTranslation,
}) {
  return [
    for (final g in groups)
      _measureGroup(g, fontSize, fontFamily, maxWidth, showTranslation),
  ];
}

double _measureGroup(
  LyricGroup g,
  double fontSize,
  String? fontFamily,
  double maxWidth,
  bool showTranslation,
) {
  var h = _textHeight(g.original.text, fontSize, fontFamily, maxWidth);
  if (showTranslation && (g.translation?.isNotEmpty ?? false)) {
    final gap = fontSize * kMainTranslationGapEm;
    h +=
        (gap < 3 ? 3 : gap) +
        _textHeight(
          g.translation!,
          fontSize * kTranslationFontScale,
          fontFamily,
          maxWidth,
        );
  }
  return h;
}

/// 单行文本排版实测高。TextPainter 按约定传入 [fontFamily]（可为 null，
/// 走默认字体）与 ltr 方向；过长时以省略号截断，不影响行高。
double _textHeight(
  String text,
  double fs,
  String? fontFamily,
  double maxWidth,
) {
  final tp = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(fontFamily: fontFamily, fontSize: fs),
    ),
    textDirection: TextDirection.ltr,
    maxLines: 1,
    ellipsis: '…',
  )..layout(maxWidth: maxWidth);
  return tp.height;
}

/// 由行高列表推每行中心（自然中心）的累计纵坐标。
///
/// 第一行中心在自身半高处；后续行中心 = 前一行中心 + 前一行半高 +
/// [gapPx] + 本行半高。空列表返回空列表。
List<double> computeCenters(
  List<double> heights, {
  double gapPx = kDefaultGapPx,
}) {
  if (heights.isEmpty) return const [];
  final centers = <double>[];
  var acc = heights[0] / 2;
  for (var i = 0; i < heights.length; i++) {
    centers.add(acc);
    if (i + 1 < heights.length) {
      acc += heights[i] / 2 + gapPx + heights[i + 1] / 2;
    }
  }
  return centers;
}
