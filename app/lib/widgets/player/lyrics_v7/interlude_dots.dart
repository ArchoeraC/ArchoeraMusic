// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 间奏（长空隙）识别。
///
/// - 两行之间「上一行真实唱完 → 下一行开始」的空隙达到
///   [kMinInterludeGapMs]（7s）即视为间奏；
/// - 间奏期间保持间奏前一行作为布局锚点、不点亮任何行（对齐 AMLL 的
///   `LyricLineAllText` 间奏语义），但不再绘制 AMLL 的三点等待动画。
///
/// 纯 Dart（无 Flutter 依赖），可单测。
///
/// 文件名为历史兼容保留（原先还承载 interlude-dots 动画）。
library;

import '../../../services/lyrics/lyric_line.dart';

/// 判定为间奏的最小空隙（毫秒，对齐 AMLL `MIN_INTERLUDE_GAP`）。
const int kMinInterludeGapMs = 7000;

/// 一段间奏（长空隙）。
class LyricInterlude {
  const LyricInterlude({
    required this.startMs,
    required this.endMs,
    required this.anchorIndex,
  });

  /// 空隙起点（上一行真实唱完的时间）。
  final int startMs;

  /// 空隙终点（下一行起始时间）。
  final int endMs;

  /// 空隙前最后一行的索引（-1 = 位于首行之前，如超长前奏）。
  final int anchorIndex;
}

/// 识别全部间奏。
///
/// 结束时间取「逐字片段的真实结束时间」优先（YRC/KRC/QRC 有字级时间轴），
/// 否则退回 [LyricGroup.endMs]（普通 LRC 的下一行起始，此时两行之间不存在
/// 可识别的空隙——与 AMLL 一致）。
List<LyricInterlude> computeInterludes(List<LyricGroup> groups) {
  final out = <LyricInterlude>[];
  if (groups.isEmpty) return out;
  var maxEnd = 0;
  for (var i = 0; i < groups.length; i++) {
    final g = groups[i];
    final start = g.original.timeMs;
    if (start - maxEnd >= kMinInterludeGapMs) {
      out.add(
        LyricInterlude(startMs: maxEnd, endMs: start, anchorIndex: i - 1),
      );
    }
    final end = _realEnd(g);
    if (end > maxEnd) maxEnd = end;
  }
  return out;
}

int _realEnd(LyricGroup g) {
  final start = g.original.timeMs;
  var end = g.endMs ?? start;
  if (end < start) end = start;
  final frags = g.fragments;
  if (frags != null) {
    for (final f in frags) {
      final d = f.durationMs ?? 0;
      if (d <= 0) continue;
      final e = start + f.startMs + d;
      if (e > end) end = e;
    }
  }
  return end;
}
