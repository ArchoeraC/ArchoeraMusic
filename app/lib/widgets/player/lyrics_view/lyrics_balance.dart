// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 普通歌词的平衡换行（对齐 SPlayer-Next / `lyric-dom` 的 `line-balance`）。
///
/// 只处理**自然折行 ≥ 2 行**的歌词：在保持行数不变的前提下，
/// 重新选择断点，让各行长度尽量接近，并优先断在标点 / 空格处，
/// 避免末行只剩一两个字。
///
/// - 纯文本行按「CJK 逐字、拉丁按词、空白/标点单独成项」切分；
/// - 逐字行以现有片段为不可再分的项（与 `lyric-dom` 以单词节点为项一致），
///   在片段之间插入换行片段，不破坏逐字时间轴；
/// - 断点用动态规划求最小代价（行宽方差 + 断点奖惩），与 `lyric-dom`
///   的 `calcBalancedBreaks` 同一套权重；
/// - 平衡后的文本会再用 `TextPainter` 复核行数，行数变化则回退原文，
///   保证不会因为测量误差把歌词撑高。
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../../services/lyrics/lyric_line.dart';

/// 平衡换行后的单行内容。
@immutable
class BalancedLyric {
  const BalancedLyric({
    required this.text,
    this.fragments,
    this.balanced = false,
  });

  /// 用于渲染 / 测量的完整文本（平衡换行已插入 `\n`）。
  final String text;

  /// 逐字片段（仅原行带逐字时间轴时非空；已插入换行片段）。
  final List<LyricFragment>? fragments;

  /// 是否实际改动了断点。
  final bool balanced;
}

/// 拟合容差（px）：吸收亚像素误差，避免平衡后浏览器/Flutter 再自然折行。
const double _fitTolerance = 0.5;

/// 单个节点自身超宽、被迫独占一行时的惩罚倍数。
const double _overflowPenaltyMultiplier = 1000;

/// 普通位置断开的惩罚比例（相对容器宽度）。
const double _normalBreakPenaltyRatio = 0.5;

/// 空格处断开的奖励比例。
const double _spaceBreakRewardRatio = 0.4;

/// 标点后断开的奖励比例（高于空格，优先在标点后换行）。
const double _punctuationBreakRewardRatio = 0.6;

/// 参与平衡换行的节点数上限，防止异常超长文本带来 O(n²) 卡顿。
const int _maxBalanceItems = 512;

/// 不可置于行首的标点（与 `lyric-dom` 的 `PUNCTUATION_START_RE` 对齐）。
final RegExp _punctuationStartRe = RegExp(r'^[,.;:!?，。；：！？、）】》」』’”)\]}>~…]');

/// 可优先在其后断行的标点。
final RegExp _punctuationEndRe = RegExp(r'[,.;:!?，。；：！？、）】》」』’”)\]}>~…]$');

/// 可单独成项的标点（含开括号，便于在括号前断行）。
const String _punctuationChars = '.,;:!?，。；：！？、）】》」』’”)]}>~…（【《「『‘“([{<';

/// 对单行歌词做平衡换行；无需 / 无法平衡时原样返回。
///
/// [maxWidth] 必须是**实际渲染宽度**（Text 的可用内容宽度），
/// [style] 必须是实际渲染文本样式，[textScaler] 取当前 `MediaQuery`。
BalancedLyric balanceLyricLine(
  LyricGroup group, {
  required double maxWidth,
  required TextStyle style,
  required TextScaler textScaler,
}) {
  final original = _original(group);
  if (maxWidth <= 0 || original.text.isEmpty) return original;
  // 已含显式换行的行不参与（平衡换行只处理 Flutter 自然折行）。
  if (original.text.contains('\n')) return original;
  // 快速排除明显放得下的短行：避免为一整首歌逐行做 TextPainter 排版。
  // （按最宽字形估算；估算偏保守，最多多做一次排版，不会漏掉需要平衡的行。）
  final estimatedFontSize = textScaler.scale(style.fontSize ?? 14);
  if (original.text.length * estimatedFontSize <= maxWidth) return original;

  final natural = _layout(original.text, style, textScaler, maxWidth);
  final rows = natural.computeLineMetrics().length;
  if (rows < 2) {
    natural.dispose();
    return original;
  }

  final fragments = original.fragments;
  final items = fragments != null && fragments.isNotEmpty
      ? _fragmentItems(natural, fragments)
      : _textItems(natural, original.text);
  final breaks = items.length < 2 || items.length > _maxBalanceItems
      ? const <int>[]
      : _calcBalancedBreaks(items, maxWidth, rows);
  if (breaks.isEmpty) {
    natural.dispose();
    return original;
  }
  natural.dispose();

  final applied = fragments != null && fragments.isNotEmpty
      ? _applyFragmentBreaks(fragments, items, breaks)
      : _applyTextBreaks(items, breaks);
  if (applied == null) return original;

  // 复核：断点只应重新分配行宽，不应改变行数。
  final check = _layout(applied.text, style, textScaler, maxWidth);
  final got = check.computeLineMetrics().length;
  check.dispose();
  return got == rows ? applied : original;
}

BalancedLyric _original(LyricGroup group) {
  final fragments = group.fragments;
  final text = fragments != null && fragments.isNotEmpty
      ? fragments.map((f) => f.text).join()
      : group.original.text;
  return BalancedLyric(text: text, fragments: fragments);
}

TextPainter _layout(
  String text,
  TextStyle style,
  TextScaler textScaler,
  double maxWidth,
) => TextPainter(
  text: TextSpan(text: text, style: style),
  textDirection: TextDirection.ltr,
  textScaler: textScaler,
)..layout(maxWidth: maxWidth);

/// 平衡换行节点。
class _BalanceItem {
  const _BalanceItem({
    required this.text,
    required this.width,
    required this.kind,
    this.fragmentIndex,
  });

  final String text;
  final double width;
  final _ItemKind kind;

  /// 逐字行中对应的片段下标（纯文本行为 null）。
  final int? fragmentIndex;

  bool get isSpace => kind == _ItemKind.space;
}

enum _ItemKind { space, cjk, punctuation, word }

/// 纯文本行：按 CJK / 拉丁词 / 空白 / 标点切项，宽度用自然排版后的
/// `getBoxesForSelection` 读取，保留字体回退与基础整形。
List<_BalanceItem> _textItems(TextPainter natural, String text) {
  final ranges = _tokenRanges(text);
  final widths = _rangesWidth(natural, [
    for (final r in ranges) (start: r.start, end: r.end),
  ]);
  final items = <_BalanceItem>[
    for (var i = 0; i < ranges.length; i++)
      _BalanceItem(
        text: ranges[i].text,
        width: widths[i],
        kind: ranges[i].kind,
      ),
  ];
  _fillSpaceWidths(items);
  return items;
}

/// 逐字行：每个现有片段是独立节点，不在片段内部再拆（保留逐字时间）。
List<_BalanceItem> _fragmentItems(
  TextPainter natural,
  List<LyricFragment> fragments,
) {
  final ranges = <({int start, int end, int fragmentIndex})>[];
  final kinds = <_ItemKind>[];
  var offset = 0;
  for (var i = 0; i < fragments.length; i++) {
    final text = fragments[i].text;
    if (text.isEmpty) continue;
    ranges.add((start: offset, end: offset + text.length, fragmentIndex: i));
    kinds.add(_classify(text.runes.first));
    offset += text.length;
  }
  final widths = _rangesWidth(natural, [
    for (final r in ranges) (start: r.start, end: r.end),
  ]);
  final items = <_BalanceItem>[
    for (var i = 0; i < ranges.length; i++)
      _BalanceItem(
        text: fragments[ranges[i].fragmentIndex].text,
        width: widths[i],
        kind: kinds[i],
        fragmentIndex: ranges[i].fragmentIndex,
      ),
  ];
  _fillSpaceWidths(items);
  return items;
}

/// 自然排版后批量读取各节点宽度（一次 layout + N 次只读查询）。
///
/// 跨行的节点会返回多段 `TextBox`，宽度相加即为视觉宽度；行尾空白可能
/// 被折叠成 0 宽，由 [_fillSpaceWidths] 用同类空白的最大宽度补齐。
List<double> _rangesWidth(
  TextPainter painter,
  List<({int start, int end})> ranges,
) => [
  for (final r in ranges)
    painter
        .getBoxesForSelection(
          TextSelection(baseOffset: r.start, extentOffset: r.end),
        )
        .fold<double>(0, (sum, box) => sum + (box.right - box.left)),
];

void _fillSpaceWidths(List<_BalanceItem> items) {
  var spaceWidth = 0.0;
  for (final item in items) {
    if (item.isSpace) spaceWidth = math.max(spaceWidth, item.width);
  }
  if (spaceWidth <= 0) return;
  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    if (item.isSpace && item.width <= 0) {
      items[i] = _BalanceItem(
        text: item.text,
        width: spaceWidth,
        kind: item.kind,
        fragmentIndex: item.fragmentIndex,
      );
    }
  }
}

/// 切分纯文本：CJK 逐字、拉丁按词、空白与标点单独成项。
List<({String text, int start, int end, _ItemKind kind})> _tokenRanges(
  String text,
) {
  final out = <({String text, int start, int end, _ItemKind kind})>[];
  var offset = 0;
  var i = 0;
  final runes = text.runes.toList();
  while (i < runes.length) {
    final start = offset;
    final r = runes[i];
    final kind = _classify(r);
    final startIndex = i;
    // 空白 / 拉丁词连续取，CJK 与标点一次只取一个字符。
    if (kind == _ItemKind.space || kind == _ItemKind.word) {
      i++;
      while (i < runes.length && _classify(runes[i]) == kind) {
        i++;
      }
    } else {
      i++;
    }
    final part = String.fromCharCodes(runes.sublist(startIndex, i));
    offset += part.length;
    out.add((text: part, start: start, end: offset, kind: kind));
  }
  return out;
}

_ItemKind _classify(int r) {
  if (r == 0x20 ||
      r == 0x09 ||
      r == 0x0A ||
      r == 0x0D ||
      r == 0x3000 ||
      r == 0x00A0) {
    return _ItemKind.space;
  }
  if (_isCjk(r)) return _ItemKind.cjk;
  final ch = String.fromCharCode(r);
  if (_punctuationChars.contains(ch)) return _ItemKind.punctuation;
  return _ItemKind.word;
}

bool _isCjk(int r) =>
    (r >= 0x3040 && r <= 0x30FF) || // 日文假名
    (r >= 0x31F0 && r <= 0x31FF) ||
    (r >= 0x3400 && r <= 0x4DBF) || // CJK 扩展 A
    (r >= 0x4E00 && r <= 0x9FFF) || // CJK 基本区
    (r >= 0xF900 && r <= 0xFAFF) || // 兼容表意文字
    (r >= 0xAC00 && r <= 0xD7AF) || // 韩文音节
    (r >= 0x20000 && r <= 0x2FA1F); // CJK 扩展 B+

/// 动态规划求断点（节点下标，升序）。
///
/// 与 `lyric-dom` 的 `calcBalancedBreaks` 对齐：
/// - 固定为 [rows] 行，最小化各行「剩余宽度²」；
/// - 标点后断开给奖励，空格处断开给较小奖励，行首标点禁止；
/// - 单个节点超宽时允许独占一行，并施加重罚。
List<int> _calcBalancedBreaks(
  List<_BalanceItem> items,
  double containerWidth,
  int rows,
) {
  final n = items.length;
  if (n == 0 || containerWidth <= 0 || rows < 2) return const [];
  final capacity = containerWidth + _fitTolerance;

  final prefixWidth = List<double>.filled(n + 1, 0);
  for (var i = 0; i < n; i++) {
    prefixWidth[i + 1] = prefixWidth[i] + items[i].width;
  }

  double rowWidth(int start, int end) {
    var width = prefixWidth[end] - prefixWidth[start];
    if (end - 1 >= start && items[end - 1].isSpace) {
      width -= items[end - 1].width;
    }
    if (start >= 0 && end - start > 1 && items[start].isSpace) {
      width -= items[start].width;
    }
    return width;
  }

  final penaltyNormal = math
      .pow(containerWidth * _normalBreakPenaltyRatio, 2)
      .toDouble();
  final rewardSpace = math
      .pow(containerWidth * _spaceBreakRewardRatio, 2)
      .toDouble();
  final rewardPunctuation = math
      .pow(containerWidth * _punctuationBreakRewardRatio, 2)
      .toDouble();

  final breakCost = List<double>.filled(n, 0);
  for (var j = 1; j < n; j++) {
    final prev = items[j - 1];
    final next = items[j];
    if (_punctuationStartRe.hasMatch(next.text)) {
      breakCost[j] = double.infinity;
    } else if (_punctuationEndRe.hasMatch(prev.text.trimRight())) {
      breakCost[j] = -rewardPunctuation;
    } else if (prev.isSpace || next.isSpace) {
      breakCost[j] = -rewardSpace;
    } else if (prev.kind == _ItemKind.cjk && next.kind == _ItemKind.cjk) {
      breakCost[j] = 0;
    } else {
      breakCost[j] = penaltyNormal;
    }
  }

  // cost[r][i]：从节点 i 起恰好排成 r 行的最小代价；next[r][i] 为下一行起点。
  final stride = n + 1;
  final cost = List<double>.filled((rows + 1) * stride, double.infinity);
  final next = List<int>.filled((rows + 1) * stride, n);
  cost[n] = 0;
  for (var r = 1; r <= rows; r++) {
    final base = r * stride;
    final prevBase = (r - 1) * stride;
    for (var i = n - 1; i >= 0; i--) {
      for (var j = i + 1; j <= n; j++) {
        final rest = cost[prevBase + j];
        if (!rest.isFinite) continue;
        final width = rowWidth(i, j);
        double lineCost;
        if (width > capacity) {
          // 多节点超宽后续只会更宽；单节点超宽则被迫独占一行。
          if (j > i + 1) break;
          lineCost =
              math.pow(width - containerWidth, 2) * _overflowPenaltyMultiplier;
        } else {
          final remain = containerWidth - width;
          lineCost = remain * remain;
        }
        final total = lineCost + (j < n ? breakCost[j] : 0) + rest;
        if (total < cost[base + i]) {
          cost[base + i] = total;
          next[base + i] = j;
        }
      }
    }
  }
  if (!cost[rows * stride].isFinite) return const [];

  final breaks = <int>[];
  var cursor = 0;
  for (var r = rows; r > 1; r--) {
    cursor = next[r * stride + cursor];
    if (cursor <= 0 || cursor >= n) return const [];
    breaks.add(cursor);
  }
  return breaks;
}

BalancedLyric? _applyTextBreaks(List<_BalanceItem> items, List<int> breaks) {
  final breakSet = breaks.toSet();
  final out = <String>[];
  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    if (breakSet.contains(i)) {
      // 断在空白处时由换行代替该空白；行尾空白也顺手去掉。
      if (out.isNotEmpty && out.last != '\n' && out.last.trimRight().isEmpty) {
        out.removeLast();
      }
      out.add('\n');
      if (item.isSpace) continue;
    }
    out.add(item.text);
  }
  final text = out.join();
  if (text.isEmpty || text == items.map((e) => e.text).join()) return null;
  return BalancedLyric(text: text, balanced: true);
}

BalancedLyric? _applyFragmentBreaks(
  List<LyricFragment> fragments,
  List<_BalanceItem> items,
  List<int> breaks,
) {
  final breakItems = <int>{...breaks};
  final out = <LyricFragment>[];
  var itemIndex = 0;
  var changed = false;
  for (final fragment in fragments) {
    if (fragment.text.isEmpty) {
      out.add(fragment);
      continue;
    }
    if (breakItems.contains(itemIndex)) {
      _trimFragmentTail(out);
      out.add(
        LyricFragment(text: '\n', startMs: fragment.startMs, durationMs: 0),
      );
      changed = true;
      final trimmed = fragment.text.trimLeft();
      if (trimmed.isEmpty) {
        itemIndex += 1;
        continue;
      }
      out.add(
        LyricFragment(
          text: trimmed,
          startMs: fragment.startMs,
          durationMs: fragment.durationMs,
        ),
      );
      itemIndex += 1;
      continue;
    }
    out.add(fragment);
    itemIndex += 1;
  }
  if (!changed) return null;
  return BalancedLyric(
    text: out.map((f) => f.text).join(),
    fragments: out,
    balanced: true,
  );
}

/// 去掉换行前一个片段末尾的空白，避免行尾空白参与排版。
void _trimFragmentTail(List<LyricFragment> out) {
  if (out.isEmpty) return;
  final last = out.last;
  if (last.text == '\n') return;
  final trimmed = last.text.trimRight();
  if (trimmed == last.text) return;
  if (trimmed.isEmpty) {
    out.removeLast();
    return;
  }
  out[out.length - 1] = LyricFragment(
    text: trimmed,
    startMs: last.startMs,
    durationMs: last.durationMs,
  );
}
