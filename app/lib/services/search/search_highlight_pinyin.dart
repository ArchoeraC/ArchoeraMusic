// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// **拼音 / 首字母命中**的行内高亮（纯 Dart；分析器为注入的可选 FFI 回调，可单测）。
///
/// 设计文档 `docs/local-search-index-plan.md` §4.2 / §2.1 第 8 项：索引侧拼音路径
/// 会召回「拉丁查询命中汉字标题」，但**字面**区间无从反推（`search_highlight.dart`
/// 只做字面匹配，对 `我爱你` + `woaini` 返回空）。本层在**字面为空**时作为补充：
///
/// 1. 把展示文本按 **CJK 段**切分（字符类与 C# `Analyzer.IsCjk` 同范围）；
/// 2. 每个 CJK 段经 [analyze]（FFI `indexer_analyze`，与索引同构）取全拼音节
///    （1 汉字 ↔ 1 音节）与首字母；
/// 3. 用查询词元的 `pinyin`（音节序列）在段内做**连续子序列匹配**（末音节可前缀，
///    与查询侧 `_pinyinBranch` 一致；单音节允许前缀，≥2 音节要求相邻且逐位相等）；
/// 4. 用查询词元的 `initials`（首字母串）与「全拼串」做**前缀 / 连续匹配**——
///    覆盖 `wan`（首字母）这类查询（`initials` 为 null 时其 `pinyin` 串即候选）；
/// 5. 合并去重、按 start 升序（[mergeMatchRanges]）。
///
/// 性能：分析器为 FFI，**只在可视行调用**、**只对 CJK 段**、结果由
/// [SearchHighlighter] 记忆化；查询词元只解析一次。
library;

import 'search_cjk_fuzzy.dart';
import 'search_highlight.dart';
import 'search_models.dart';

/// 拼音 / 首字母命中的高亮区间（半开 `[start, end)`）。
///
/// [text] 为展示文本；[queryTokens] 为查询经分析器得到的词元（`pinyin` /
/// `initials` / `lexical`）；[analyze] 为文本分析器（与索引同构）。
/// 无分析器 / 无 CJK 段 / 无命中返回 `const []`。
List<MatchRange> highlightRangesWithTokens(
  String text,
  AnalyzerTokens queryTokens, {
  required AnalyzerTokens? Function(String text) analyze,
}) {
  if (text.isEmpty || queryTokens.isEmpty) return const [];

  final ranges = <MatchRange>[];
  for (final segment in _cjkSegments(text)) {
    AnalyzerTokens? segmentTokens;
    try {
      segmentTokens = analyze(segment.text);
    } catch (_) {
      continue; // 分析失败不中断其余段
    }
    if (segmentTokens == null) continue;

    final syllables = segmentTokens.pinyin;
    // 1 汉字 ↔ 1 音节；长度不符则对齐不可靠，跳过该段的拼音匹配。
    if (syllables.isEmpty || syllables.length != segment.text.length) continue;

    ranges.addAll(_matchPinyin(queryTokens.pinyin, syllables, segment.start));
    ranges.addAll(_matchInitials(
      queryTokens: queryTokens,
      segmentInitials: _initialsOf(syllables),
      segmentStart: segment.start,
    ));
  }
  return mergeMatchRanges(ranges);
}

/// 文本内的 CJK 段（[text] 与其在原文中的 UTF-16 起始下标）。
class _CjkSegment {
  const _CjkSegment(this.text, this.start);

  final String text;
  final int start;
}

/// 把 [text] 切为**连续 CJK 段**（保序，记录起始下标）；非 CJK 段跳过。
List<_CjkSegment> _cjkSegments(String text) {
  final out = <_CjkSegment>[];
  var i = 0;
  while (i < text.length) {
    if (!isCjkCodeUnit(text.codeUnitAt(i))) {
      i++;
      continue;
    }
    final start = i;
    while (i < text.length && isCjkCodeUnit(text.codeUnitAt(i))) {
      i++;
    }
    out.add(_CjkSegment(text.substring(start, i), start));
  }
  return out;
}

/// 音节序列 → 首字母串（每音节首字符；BMP CJK 首字母为 ASCII）。
String _initialsOf(List<String> syllables) {
  final buf = StringBuffer();
  for (final syllable in syllables) {
    if (syllable.isNotEmpty) buf.write(syllable[0]);
  }
  return buf.toString();
}

/// 音节序列匹配：查询音节在段内**连续**命中（与查询侧 [_pinyinBranch] 同构——
/// 单音节允许前缀 `"wo"*`；≥2 音节要求逐位相等，即相邻短语 `"wo ai ni"`）。
List<MatchRange> _matchPinyin(
  List<String> querySyllables,
  List<String> segmentSyllables,
  int offset,
) {
  final query = _normalize(querySyllables);
  if (query.isEmpty || query.length > segmentSyllables.length) return const [];

  final prefixLast = query.length == 1;
  final out = <MatchRange>[];
  for (var start = 0; start + query.length <= segmentSyllables.length; start++) {
    if (_runMatches(segmentSyllables, start, query, prefixLast: prefixLast)) {
      out.add(MatchRange(offset + start, offset + start + query.length));
    }
  }
  return out;
}

/// 从 [start] 起，`query` 各行与段音节逐位匹配；[prefixLast] 为真时末音节允许前缀
/// （仅单音节查询），其余要求完全相等。
bool _runMatches(
  List<String> syllables,
  int start,
  List<String> query, {
  required bool prefixLast,
}) {
  for (var k = 0; k < query.length; k++) {
    final segment = syllables[start + k].toLowerCase();
    final token = query[k];
    if (k == query.length - 1 && prefixLast) {
      if (!segment.startsWith(token)) return false;
    } else if (segment != token) {
      return false;
    }
  }
  return true;
}

/// 首字母匹配：候选为查询的 `initials` 各段、查询全拼串、查询词法串（去空白、小写）。
///
/// 候选在段首字母串中做**前缀 / 连续**（子串）匹配；命中区间按「1 首字母 ↔ 1 汉字」
/// 映射回汉字下标。覆盖 `wan`（首字母）/ `woaini`（全拼，前缀不成立时也兜底）。
List<MatchRange> _matchInitials({
  required AnalyzerTokens queryTokens,
  required String segmentInitials,
  required int segmentStart,
}) {
  final initials = segmentInitials.toLowerCase();
  if (initials.isEmpty) return const [];

  final candidates = <String>{
    ..._splitLower(queryTokens.initials),
    _joinLower(queryTokens.pinyin),
    _joinLower(queryTokens.lexical),
  }..removeWhere((c) => c.isEmpty || c.length > initials.length);
  if (candidates.isEmpty) return const [];

  final ranges = <MatchRange>[];
  for (final candidate in candidates) {
    var from = 0;
    while (from <= initials.length - candidate.length) {
      final index = initials.indexOf(candidate, from);
      if (index < 0) break;
      ranges.add(MatchRange(
        segmentStart + index,
        segmentStart + index + candidate.length,
      ));
      from = index + 1;
    }
  }
  return ranges;
}

/// 按空白切分并小写（`initials` 可能是 `song wan` 这类分段串）。
List<String> _splitLower(String? raw) {
  if (raw == null) return const [];
  return raw
      .split(RegExp(r'\s+'))
      .where((t) => t.isNotEmpty)
      .map((t) => t.toLowerCase())
      .toList();
}

/// 归一化音节 / 词元列表：trim + 小写 + 去空。
List<String> _normalize(List<String> tokens) => tokens
    .map((t) => t.trim().toLowerCase())
    .where((t) => t.isNotEmpty)
    .toList();

/// 连接为单个小写串（用于全拼 / 词法作为首字母候选）。
String _joinLower(List<String> tokens) => _normalize(tokens).join();
