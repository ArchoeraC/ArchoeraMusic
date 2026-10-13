// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 本地搜索**结果高亮**的纯函数层（无 FFI / 无 IO / 无 Flutter 依赖，可单测）。
///
/// 设计文档 `docs/local-search-index-plan.md` §2.1 第 8 项「结果高亮」：索引
/// 排行只给出「哪几首命中」，但**为什么命中**（标题 / 歌手 / 专辑里的哪一段）
/// 需要 UI 自行从**查询串 + 展示文本**求区间。索引命中是分析后的词元（CJK
/// bigram / 拼音音节），无法反推原始字符下标，故这里**独立**做一次轻量**字面**
/// 匹配——只作展示层增强，不参与召回。
///
/// 语义（与分析器侧的归一化**方向一致**，但**不依赖 FFI**）：
/// - 大小写不敏感；
/// - 查询先 `trim`，折叠**全角 ASCII → 半角**并把连续空白折叠为单空格；
/// - 文本侧同样折叠全角 / 半角（全角 `Ａ`/`１`/`　` 等）；
/// - 含空格的查询**额外尝试去空格版本**（`wo ai` ↔ `woai`）；
/// - 返回**合并 / 去重、按 start 升序**的半开区间（UTF-16 码元下标，与
///   `String.substring` 一致）；
/// - **不误高亮拼音 / 首字母命中**：查询为拉丁、文本为汉字（拼音路径命中）时
///   没有直接字面区间 → [highlightRanges] 返回空；由 [SearchHighlighter] 的拼音
///   补充路径（`search_highlight_pinyin.dart`）负责，宁可不亮也不乱亮。
library;

import 'search_highlight_pinyin.dart';
import 'search_models.dart';

/// 单段命中区间（半开 `[start, end)`，UTF-16 码元下标）。
///
/// 不直接用 `dart:ui` 的 `TextRange`，以保持本层无 Flutter 依赖、可纯 Dart 单测；
/// UI 侧再据此构造 `TextSpan`。
class MatchRange {
  const MatchRange(this.start, this.end);

  /// 起始下标（含）。
  final int start;

  /// 结束下标（不含）。
  final int end;

  int get length => end - start;

  bool get isEmpty => end <= start;

  @override
  bool operator ==(Object other) =>
      other is MatchRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'MatchRange($start, $end)';
}

/// 连续空白折叠（查询 / 文本归一化共用）。
final RegExp _whitespaceRun = RegExp(r'\s+');

/// **保长**归一化：逐码元折叠「全角 ASCII → 半角」「全角空格 → 半角空格」，
/// 并把能**单码元**小写的字符转小写。
///
/// 关键不变量：返回串与 [input] **等长**（同码元数）——这样在归一化文本上求得的
/// 区间可直接用于原始文本切片，避免 `String.toLowerCase()`（个别字符变长，如
/// `İ`）导致的下标错位。
String _fold(String input) {
  final buf = StringBuffer();
  for (var i = 0; i < input.length; i++) {
    var unit = input.codeUnitAt(i);
    if (unit >= 0xFF01 && unit <= 0xFF5E) {
      unit -= 0xFEE0; // 全角 ASCII（！..～）→ 半角（!..~）
    } else if (unit == 0x3000) {
      unit = 0x20; // 全角空格 → 半角空格
    }
    final ch = String.fromCharCode(unit);
    final lower = ch.toLowerCase();
    buf.write(lower.length == 1 ? lower : ch);
  }
  return buf.toString();
}

/// 查询归一化：全角折叠 → 小写 → 折叠连续空白 → trim。
String _normalizeQuery(String query) =>
    _fold(query).replaceAll(_whitespaceRun, ' ').trim();

/// 在 [text] 中查找 [query] 的全部字面命中区间（**纯函数**）。
///
/// 详情见库级文档注释；无命中 / 空文本 / 空查询返回 `const []`。
List<MatchRange> highlightRanges(String text, String query) {
  if (text.isEmpty) return const [];
  final normalized = _normalizeQuery(query);
  if (normalized.isEmpty) return const [];

  final foldedText = _fold(text);

  // 查询变体：折叠空白版 + 去空白版（两者相同时自动去重）。
  final variants = <String>{normalized};
  final noSpace = normalized.replaceAll(' ', '');
  if (noSpace.isNotEmpty) variants.add(noSpace);

  final ranges = <MatchRange>[];
  for (final variant in variants) {
    final needle = _fold(variant);
    if (needle.isEmpty) continue;
    var from = 0;
    while (from <= foldedText.length - needle.length) {
      final index = foldedText.indexOf(needle, from);
      if (index < 0) break;
      ranges.add(MatchRange(index, index + needle.length));
      from = index + needle.length; // 非重叠：命中段整体高亮即可
    }
  }
  return mergeMatchRanges(ranges);
}

/// 合并**重叠或相邻**区间并去重，按 start 升序（可视化等价的最小覆盖集）。
///
/// 公开供拼音 / 首字母高亮（`search_highlight_pinyin.dart`）复用同一去重语义。
List<MatchRange> mergeMatchRanges(List<MatchRange> ranges) {
  if (ranges.isEmpty) return const [];
  final sorted = List<MatchRange>.of(ranges)
    ..sort((a, b) => a.start != b.start
        ? a.start.compareTo(b.start)
        : a.end.compareTo(b.end));
  final merged = <MatchRange>[sorted.first];
  for (var i = 1; i < sorted.length; i++) {
    final last = merged.last;
    final next = sorted[i];
    // 相邻（next.start == last.end）也合并：覆盖文字连续，视觉一致。
    if (next.start <= last.end) {
      if (next.end > last.end) merged[merged.length - 1] = MatchRange(last.start, next.end);
    } else {
      merged.add(next);
    }
  }
  return merged;
}

/// 命中附近的**摘要窗口**（可选便利函数）：返回首个命中前后各约 [radius]
/// 个字符的片段，被裁剪端加省略号「…」；无命中返回 `null`。
///
/// 用于未来「歌词命中」等跨行场景的窄窗展示；列表行内高亮不依赖它。
String? snippet(String text, String query, {int radius = 24}) {
  final ranges = highlightRanges(text, query);
  if (ranges.isEmpty) return null;
  final first = ranges.first;
  var start = first.start - radius;
  var end = first.end + radius;
  if (start < 0) start = 0;
  if (end > text.length) end = text.length;
  final prefix = start > 0 ? '…' : '';
  final suffix = end < text.length ? '…' : '';
  return '$prefix${text.substring(start, end)}$suffix';
}

/// **有界记忆化**高亮器：同一查询串下，同一段文本只计算一次区间。
///
/// 列表（`ListView.builder`）每帧只构建视口附近的行，且行会因悬停 / 播放态
/// 频繁 rebuild；若每次 build 都重算，虽为 O(文本长度) 但仍是**每帧重复计算**。
/// 本类按「展示文本」缓存区间，滚动 / 重建命中缓存即 O(1)；文本种类受视口 +
/// 驻留页约束，缓存以 [maxEntries] 为上限（超限整体清空后重建，区间廉价且
/// 查询不变时极少触发），避免随全库滚动无界增长。
///
/// 查询变化时**整体作废**（调用方按查询串重新构造）。
///
/// **拼音 / 首字母补充**（[analyzer] 非空时，设计文档 §4.2 / §2.1「结果高亮」）：
/// 字面 [highlightRanges] 无命中时，用查询分析词元（`pinyin` / `initials`）在
/// **CJK 段**内做连续匹配，命中汉字区间（`search_highlight_pinyin.dart`）。
/// 分析器调用**昂贵**且为 FFI：查询侧只在首次需要时分析一次；文本侧按段 + 记忆化，
/// 同一行不重复分析。关闭态（[analyzer] 为 null）零成本、外观不变。
class SearchHighlighter {
  SearchHighlighter(
    this.query, {
    this.maxEntries = 512,
    this.analyzer,
  });

  /// 已归一化的查询串（原样保留供调用方比对 / 诊断）。
  final String query;

  /// 缓存条目上限（超出后清空重建，保证内存有界）。
  final int maxEntries;

  /// 可选查询 / 文本分析器（FFI `indexer_analyze`）；null = 仅字面高亮。
  final AnalyzerTokens? Function(String text)? analyzer;

  final Map<String, List<MatchRange>> _cache = {};

  /// 查询分析词元（惰性求值一次；[query] 不变故只需一次）。
  AnalyzerTokens? _queryTokens;
  bool _queryResolved = false;

  /// 当前缓存条目数（测试 / 诊断用）。
  int get cacheSize => _cache.length;

  /// 求 [text] 的高亮区间（命中缓存时不重算）。
  ///
  /// 先字面匹配；字面为空且配置了 [analyzer] 时，再尝试拼音 / 首字母命中。
  List<MatchRange> call(String text) {
    final cached = _cache[text];
    if (cached != null) return cached;

    var ranges = highlightRanges(text, query);
    if (ranges.isEmpty) {
      final analyzer = this.analyzer;
      if (analyzer != null) {
        final queryTokens = _resolveQueryTokens(analyzer);
        if (queryTokens != null && !queryTokens.isEmpty) {
          try {
            final pinyinHits =
                highlightRangesWithTokens(text, queryTokens, analyze: analyzer);
            if (pinyinHits.isNotEmpty) ranges = pinyinHits;
          } catch (_) {
            // 分析器异常不影响字面高亮（降级为空区间）。
          }
        }
      }
    }

    if (_cache.length >= maxEntries) _cache.clear();
    _cache[text] = ranges;
    return ranges;
  }

  /// 惰性解析查询词元（失败 / 未就绪缓存为 null，避免每次行 build 重复调用分析器）。
  AnalyzerTokens? _resolveQueryTokens(AnalyzerTokens? Function(String) analyzer) {
    if (_queryResolved) return _queryTokens;
    _queryResolved = true;
    try {
      return _queryTokens = analyzer(query);
    } catch (_) {
      return _queryTokens = null;
    }
  }
}
