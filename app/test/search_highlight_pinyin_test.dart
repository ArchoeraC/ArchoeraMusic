// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 拼音 / 首字母命中行内高亮的**纯函数单测**（带桩分析器，无 FFI）。
///
/// 覆盖设计文档 `docs/local-search-index-plan.md` §4.2 / §2.1 第 8 项：
/// 全拼连续匹配（末音节前缀）、首字母前缀 / 连续匹配、非 CJK 前缀偏移、
/// 合并去重排序、空 / 未知输入，以及 [SearchHighlighter] 的「字面优先 + 记忆化」。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/search/search_highlight.dart';
import 'package:archoera_music/services/search/search_highlight_pinyin.dart';
import 'package:archoera_music/services/search/search_models.dart';

/// 与真实分析器同构的**桩**：只覆盖测试用文本（1 汉字 ↔ 1 音节）。
///
/// 同时覆盖「文本段」与「查询串」（[SearchHighlighter] 会用同一分析器分析查询）。
AnalyzerTokens? _stubAnalyze(String text) => switch (text) {
  '我爱你' => const AnalyzerTokens(
    lexical: ['我爱', '爱你', '我', '爱', '你'],
    pinyin: ['wo', 'ai', 'ni'],
    initials: 'wan',
  ),
  '你爱我' => const AnalyzerTokens(
    lexical: ['你我', '爱我', '你', '爱', '我'],
    pinyin: ['ni', 'ai', 'wo'],
    initials: 'naw',
  ),
  'woaini' => const AnalyzerTokens(
    lexical: ['woaini'],
    pinyin: ['wo', 'ai', 'ni'],
  ),
  'wan' => const AnalyzerTokens(lexical: ['wan'], pinyin: ['wan']),
  '爱你' => const AnalyzerTokens(
    lexical: ['爱你', '爱', '你'],
    pinyin: ['ai', 'ni'],
    initials: 'an',
  ),
  _ => null,
};

void main() {
  group('highlightRangesWithTokens 全拼', () {
    test('woaini（连写全拼）命中整段汉字', () {
      final ranges = highlightRangesWithTokens(
        '我爱你',
        const AnalyzerTokens(lexical: ['woaini'], pinyin: ['wo', 'ai', 'ni']),
        analyze: _stubAnalyze,
      );
      expect(ranges, const [MatchRange(0, 3)]);
    });

    test('woai（末音节前缀）命中前两字', () {
      final ranges = highlightRangesWithTokens(
        '我爱你',
        const AnalyzerTokens(pinyin: ['wo', 'ai']),
        analyze: _stubAnalyze,
      );
      expect(ranges, const [MatchRange(0, 2)]);
    });

    test('wo（单音节前缀）命中首字', () {
      final ranges = highlightRangesWithTokens(
        '我爱你',
        const AnalyzerTokens(pinyin: ['wo']),
        analyze: _stubAnalyze,
      );
      expect(ranges, const [MatchRange(0, 1)]);
    });

    test('词中连续命中（ai ni）映射到后两字', () {
      final ranges = highlightRangesWithTokens(
        '我爱你',
        const AnalyzerTokens(pinyin: ['ai', 'ni']),
        analyze: _stubAnalyze,
      );
      expect(ranges, const [MatchRange(1, 3)]);
    });
  });

  group('highlightRangesWithTokens 首字母', () {
    test('wan（首字母）命中整段汉字', () {
      final ranges = highlightRangesWithTokens(
        '我爱你',
        const AnalyzerTokens(lexical: ['wan'], pinyin: ['wan']),
        analyze: _stubAnalyze,
      );
      expect(ranges, const [MatchRange(0, 3)]);
    });

    test('首字母前缀 wa 命中前两字', () {
      final ranges = highlightRangesWithTokens(
        '我爱你',
        const AnalyzerTokens(initials: 'wa'),
        analyze: _stubAnalyze,
      );
      expect(ranges, const [MatchRange(0, 2)]);
    });

    test('首字母连续子串 an 命中后两字', () {
      final ranges = highlightRangesWithTokens(
        '我爱你',
        const AnalyzerTokens(initials: 'an'),
        analyze: _stubAnalyze,
      );
      expect(ranges, const [MatchRange(1, 3)]);
    });
  });

  group('highlightRangesWithTokens 偏移 / 边界', () {
    test('非 CJK 前缀：区间偏移正确', () {
      final ranges = highlightRangesWithTokens(
        'Song我爱你',
        const AnalyzerTokens(pinyin: ['wo', 'ai', 'ni']),
        analyze: _stubAnalyze,
      );
      // 'Song' 占 4 码元，汉字段从下标 4 起。
      expect(ranges, const [MatchRange(4, 7)]);
    });

    test('无分析器结果 / 词元为空 / 无 CJK 段 → 空', () {
      expect(
        highlightRangesWithTokens(
          '我爱你',
          const AnalyzerTokens(pinyin: ['wo']),
          analyze: (_) => null,
        ),
        isEmpty,
      );
      expect(
        highlightRangesWithTokens(
          '我爱你',
          const AnalyzerTokens(),
          analyze: _stubAnalyze,
        ),
        isEmpty,
      );
      expect(
        highlightRangesWithTokens(
          'abc',
          const AnalyzerTokens(pinyin: ['wo']),
          analyze: _stubAnalyze,
        ),
        isEmpty,
      );
    });

    test('不匹配的拉丁查询不误高亮', () {
      final ranges = highlightRangesWithTokens(
        '我爱你',
        const AnalyzerTokens(lexical: ['hello'], pinyin: ['hello']),
        analyze: _stubAnalyze,
      );
      expect(ranges, isEmpty);
    });
  });

  group('SearchHighlighter 字面优先 + 拼音补充 + 记忆化', () {
    test('字面命中优先（拼音不覆盖字面区间）', () {
      final h = SearchHighlighter('爱你', analyzer: _stubAnalyze);
      expect(h('我爱你'), const [MatchRange(1, 3)]);
    });

    test('字面为空 → 拼音补充命中', () {
      final h = SearchHighlighter('woaini', analyzer: _stubAnalyze);
      expect(h('我爱你'), const [MatchRange(0, 3)]);
      final wan = SearchHighlighter('wan', analyzer: _stubAnalyze);
      expect(wan('我爱你'), const [MatchRange(0, 3)]);
    });

    test('无分析器：拼音路径关闭（外观不变）', () {
      final h = SearchHighlighter('woaini');
      expect(h('我爱你'), isEmpty);
    });

    test('记忆化：同一文本只分析 / 计算一次', () {
      var analyzeCalls = 0;
      AnalyzerTokens? counting(String text) {
        analyzeCalls++;
        return _stubAnalyze(text);
      }

      final h = SearchHighlighter('woaini', analyzer: counting);
      expect(h('我爱你'), const [MatchRange(0, 3)]);
      final afterFirst = analyzeCalls;
      expect(h('我爱你'), const [MatchRange(0, 3)]);
      expect(h.cacheSize, 1);
      expect(analyzeCalls, afterFirst, reason: '缓存命中不应再次分析');
      expect(afterFirst, 2, reason: '查询一次 + 文本段一次');
    });

    test('查询分析失败（未就绪）降级为字面，不抛异常', () {
      final h = SearchHighlighter('woaini', analyzer: (_) => null);
      expect(h('我爱你'), isEmpty);
      expect(h('Love'), isEmpty);
    });
  });
}
