// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 本地搜索结果高亮的**纯函数单测**（无 FFI / 无 Flutter widget）。
///
/// 覆盖设计文档 `docs/local-search-index-plan.md` §2.1 第 8 项语义：
/// 中文子串、大小写不敏感、全角 / 半角折叠、含空格查询（去空格变体）、
/// 多次命中合并去重排序、无命中、空查询，以及「拼音 / 首字母命中不误高亮」。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/search/search_highlight.dart';

void main() {
  group('highlightRanges 基础匹配', () {
    test('中文子串：返回原文下标区间', () {
      expect(highlightRanges('我爱你中国', '中国'), const [MatchRange(3, 5)]);
      expect(highlightRanges('我好爱你啊', '爱你'), const [MatchRange(2, 4)]);
    });

    test('大小写不敏感（文本 / 查询任一侧的大小写都归一）', () {
      expect(highlightRanges('Love Story', 'love'), const [MatchRange(0, 4)]);
      expect(highlightRanges('Love Story', 'LOVE'), const [MatchRange(0, 4)]);
      expect(highlightRanges('love story', 'Love'), const [MatchRange(0, 4)]);
    });

    test('文本 / 查询两侧都做全角 → 半角折叠', () {
      // 文本全角、查询半角。
      expect(highlightRanges('ＬＯＶＥ', 'love'), const [MatchRange(0, 4)]);
      // 文本半角、查询全角。
      expect(highlightRanges('love', 'ＬＯＶＥ'), const [MatchRange(0, 4)]);
      // 全角数字。
      expect(highlightRanges('ＡＢ１２', 'ab12'), const [MatchRange(0, 4)]);
    });

    test('全角空格（U+3000）等价半角空格', () {
      expect(highlightRanges('wo　ai', 'wo ai'), const [MatchRange(0, 5)]);
    });
  });

  group('含空格查询', () {
    test('原样命中', () {
      expect(highlightRanges('wo ai ni', 'wo ai'), const [MatchRange(0, 5)]);
    });

    test('额外尝试去空格版本（文本无空格）', () {
      // 查询 `wo ai` → 去空格变体 `woai` 命中 `woaini` 的前 4 个字符。
      expect(highlightRanges('woaini', 'wo ai'), const [MatchRange(0, 4)]);
    });

    test('查询多余空白折叠为单空格', () {
      expect(
        highlightRanges('hello world', 'hello   world'),
        const [MatchRange(0, 11)],
      );
    });
  });

  group('区间合并 / 去重 / 排序', () {
    test('多次非相邻命中按 start 升序', () {
      expect(
        highlightRanges('abc xabc', 'abc'),
        const [MatchRange(0, 3), MatchRange(5, 8)],
      );
    });

    test('相邻命中合并为一段（视觉等价）', () {
      expect(highlightRanges('abab', 'ab'), const [MatchRange(0, 4)]);
    });

    test('同一段被多个查询变体命中时去重', () {
      // 查询 `wo ai` 的两个变体都命中同一区间。
      final ranges = highlightRanges('woai', 'wo ai');
      expect(ranges, const [MatchRange(0, 4)]);
    });
  });

  group('无命中 / 空输入', () {
    test('无字面命中返回空', () {
      expect(highlightRanges('abc', 'xyz'), isEmpty);
      expect(highlightRanges('abc', 'abcd'), isEmpty);
    });

    test('空文本 / 空查询 / 纯空白查询返回空', () {
      expect(highlightRanges('', 'a'), isEmpty);
      expect(highlightRanges('abc', ''), isEmpty);
      expect(highlightRanges('abc', '   '), isEmpty);
      expect(highlightRanges('abc', '\u3000'), isEmpty);
    });

    test('拼音 / 首字母命中（拉丁查询 + 汉字文本）不误高亮', () {
      // 索引侧拼音路径会召回，但行内没有可直接高亮的字面区间。
      expect(highlightRanges('我爱你', 'woai'), isEmpty);
      expect(highlightRanges('我爱你', 'wan'), isEmpty);
    });
  });

  group('MatchRange 值语义', () {
    test('相等与哈希一致', () {
      expect(const MatchRange(1, 3), const MatchRange(1, 3));
      expect(const MatchRange(1, 3).hashCode, const MatchRange(1, 3).hashCode);
      expect(const MatchRange(1, 3), isNot(const MatchRange(1, 4)));
      expect(const MatchRange(1, 3).length, 2);
    });
  });

  group('snippet', () {
    test('命中附近窗口含命中串；无命中返回 null', () {
      final s = snippet('hello world', 'world', radius: 3);
      expect(s, isNotNull);
      expect(s, contains('world'));
      expect(snippet('abc', 'xyz'), isNull);
    });
  });

  group('SearchHighlighter 记忆化', () {
    test('同一文本只计算一次（缓存命中）', () {
      final h = SearchHighlighter('love');
      expect(h('Love Story'), const [MatchRange(0, 4)]);
      expect(h('Love Story'), const [MatchRange(0, 4)]);
      expect(h.cacheSize, 1);
    });

    test('缓存有界：超过上限后不无界增长', () {
      final h = SearchHighlighter('a', maxEntries: 2);
      h('a1');
      h('a2');
      h('a3');
      expect(h.cacheSize, lessThanOrEqualTo(2));
    });
  });
}
