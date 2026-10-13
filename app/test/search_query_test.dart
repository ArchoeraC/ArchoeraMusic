// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/search/search_models.dart';
import 'package:archoera_music/services/search/search_query.dart';

/// FTS5 `MATCH` 表达式编译的**纯单测**（无 FFI / 无 DB）。
///
/// 覆盖：中文子串（bigram+unigram）、**连续 bigram 引号短语**（P4）、拼音音节、
/// **首音节前缀变体**（P4）、首字母、拉丁前缀、scope 列过滤，以及特殊字符
/// （`"` / `*` / `(` / `:`）的转义安全与空输入。
void main() {
  group('compileMatch 基础', () {
    test('空输入返回 null', () {
      expect(compileMatch(const AnalyzerTokens()), isNull);
      expect(compileMatch(const AnalyzerTokens(lexical: ['', '  '])), isNull);
      expect(compileMatch(const AnalyzerTokens(initials: '   ')), isNull);
      expect(compileMatch(const AnalyzerTokens(pinyin: [''])), isNull);
    });

    test('中文：连续多个 bigram → 引号短语，unigram 维持 AND', () {
      final expr = compileMatch(const AnalyzerTokens(
        lexical: ['我爱', '爱你', '我', '爱', '你'],
      ));
      // 连续 bigram [我爱, 爱你] 合并为短语；unigram 逐个 AND。
      expect(expr, '"我爱 爱你" AND "我" AND "爱" AND "你"');
    });

    test('中文：单个 bigram 维持现状（不加短语）', () {
      expect(
        compileMatch(const AnalyzerTokens(lexical: ['我爱'])),
        '"我爱"',
      );
      // 交替 bigram（非连续）不合并。
      expect(
        compileMatch(const AnalyzerTokens(lexical: ['我爱', 'a', '爱你', '我'])),
        '"我爱" AND "a" AND "爱你" AND "我"',
      );
    });

    test('中文长词：连续 bigram 全并入短语', () {
      final expr = compileMatch(const AnalyzerTokens(
        lexical: ['我爱', '爱你', '你中', '中国', '我', '爱', '你', '中', '国'],
      ));
      expect(expr, '"我爱 爱你 你中 中国" AND "我" AND "爱" AND "你" AND "中" AND "国"');
    });

    test('中英混合：CJK 短语 + 拉丁前缀（末拉丁加 *）', () {
      final expr = compileMatch(const AnalyzerTokens(
        lexical: ['我爱', '爱你', '我', '爱', '你', 'love'],
      ));
      expect(expr, '"我爱 爱你" AND "我" AND "爱" AND "你" AND "love"*');
    });

    test('拼音：音节 AND，末音节加前缀 *；≥2 音节附首音节前缀变体', () {
      final expr = compileMatch(const AnalyzerTokens(pinyin: ['wo', 'ai', 'ni']));
      expect(expr, '("wo" AND "ai" AND "ni"* OR "wo"* AND "ai" AND "ni"*)');
    });

    test('拼音：单音节只用主形态（末音节 *）', () {
      expect(compileMatch(const AnalyzerTokens(pinyin: ['wo'])), '"wo"*');
    });

    test('拼音：双音节附首音节前缀变体（覆盖 w ai 混合输入）', () {
      final expr = compileMatch(const AnalyzerTokens(pinyin: ['w', 'ai']));
      expect(expr, '("w" AND "ai"* OR "w"* AND "ai"*)');
    });

    test('首字母：整串加前缀 *', () {
      expect(compileMatch(const AnalyzerTokens(initials: 'wan')), '"wan"*');
    });

    test('拉丁/数字：末 token 前缀，非末 token 不加', () {
      expect(
        compileMatch(const AnalyzerTokens(lexical: ['love'])),
        '"love"*',
      );
      expect(
        compileMatch(const AnalyzerTokens(lexical: ['love', 'song'])),
        '"love" AND "song"*',
      );
    });

    test('三支以 OR 组合（任一层命中即召回）', () {
      final expr = compileMatch(const AnalyzerTokens(
        lexical: ['a'],
        pinyin: ['wo'],
        initials: 'wan',
      ));
      expect(expr, '("a"* OR "wo"* OR "wan"*)');
    });

    test('连写全拼（分析器切分后）编译：woaini → wo/ai/ni 三支', () {
      // AnalyzeQuery('woaini') 的原生输出：lexical=woaini、pinyin=wo ai ni、initials=null。
      final expr = compileMatch(const AnalyzerTokens(
        lexical: ['woaini'],
        pinyin: ['wo', 'ai', 'ni'],
      ));
      expect(
        expr,
        '("woaini"* OR ("wo" AND "ai" AND "ni"* OR "wo"* AND "ai" AND "ni"*))',
      );
    });
  });

  group('scope 列过滤', () {
    test('metadata：单支 AND 整体加括号过滤', () {
      final expr = compileMatch(
        const AnalyzerTokens(lexical: ['love', 'song']),
        scope: LocalSearchScope.metadata,
      );
      expect(
        expr,
        '{title_tok artist_tok album_tok filename_tok pinyin_tok} : '
        '("love" AND "song"*)',
      );
    });

    test('metadata：多支 OR 整体加括号过滤', () {
      final expr = compileMatch(
        const AnalyzerTokens(lexical: ['love'], pinyin: ['wo'], initials: 'wan'),
        scope: LocalSearchScope.metadata,
      );
      expect(
        expr,
        '{title_tok artist_tok album_tok filename_tok pinyin_tok} : '
        '("love"* OR "wo"* OR "wan"*)',
      );
    });

    test('all：不加列过滤', () {
      final expr = compileMatch(const AnalyzerTokens(lexical: ['love']));
      expect(expr, '"love"*');
      expect(expr!.contains('title_tok'), isFalse);
    });
  });

  group('特殊字符安全（转义，杜绝语法错误 / 注入）', () {
    test('双引号翻倍', () {
      expect(quoteToken('a"b'), '"a""b"');
      expect(quoteToken('"'), '""""');
    });

    test('包含 * ( : 等按字面量加引号', () {
      expect(
        compileMatch(const AnalyzerTokens(lexical: ['a"b', 'a*b', '(', ':'])),
        '"a""b" AND "a*b" AND "(" AND ":"*',
      );
    });

    test('注入尝试被当作字面量（值整体加引号）', () {
      // 尝试闭合引号注入 `OR`：整体加引号后不成立。
      final expr = compileMatch(
        const AnalyzerTokens(lexical: ['x" OR "y']),
      );
      expect(expr, '"x"" OR ""y"*');
    });

    test('含引号的「类 bigram」不入短语，仍按字面量转义', () {
      // '我"' 仅一字为 CJK → 非 bigram，不合并；quoteToken 内部 " 翻倍。
      final expr = compileMatch(
        const AnalyzerTokens(lexical: ['我"', '"爱']),
      );
      expect(expr, '"我""" AND """爱"');
    });
  });

  group('compileFuzzy 容错（编辑距离 ≤ 1）', () {
    test('空输入返回 null；纯 CJK 与精确路径一致', () {
      expect(compileFuzzy(const AnalyzerTokens()), isNull);
      const cjk = AnalyzerTokens(
        lexical: ['我爱', '爱你'],
        pinyin: ['wo', 'ai'],
        initials: 'wa',
      );
      expect(compileFuzzy(cjk), compileMatch(cjk));
    });

    test('hasFuzzyEligible：拉丁/数字为真，纯 CJK 为假', () {
      expect(hasFuzzyEligible(const AnalyzerTokens(lexical: ['hello'])), isTrue);
      expect(hasFuzzyEligible(const AnalyzerTokens(lexical: ['hello', '123'])),
          isTrue);
      expect(hasFuzzyEligible(const AnalyzerTokens(lexical: ['我爱', '我'])),
          isFalse);
      expect(hasFuzzyEligible(const AnalyzerTokens()), isFalse);
    });

    test('短词 cat：删除/换位/受限替换 + 末词元每个变体加前缀 *', () {
      final expr = compileFuzzy(const AnalyzerTokens(lexical: ['cat']));
      expect(
        expr,
        '("cat"* OR "at"* OR "ct"* OR "ca"* OR "act"* OR "cta"* '
        'OR "kat"* OR "sat"* OR "zat"* OR "cet"* OR "cit"* OR "cot"* '
        'OR "cut"* OR "cad"*)',
      );
    });

    test('hello：含删除(helo/hllo)、元音替换(hallo) 等变体且保留原词', () {
      final expr = compileFuzzy(const AnalyzerTokens(lexical: ['hello']))!;
      expect(expr, contains('"helo"*')); // 删除
      expect(expr, contains('"hllo"*')); // 删除 e
      expect(expr, contains('"hallo"*')); // e → a 受限替换
      expect(expr, contains('"hello"*')); // 原词始终保留
    });

    test('转义安全：不可扩展（含引号）词元退回精确加引号', () {
      expect(
        compileFuzzy(const AnalyzerTokens(lexical: ['a"b'])),
        '"a""b"*',
      );
    });

    test('变体预算：超 maxVariants 只扩展末个拉丁词元', () {
      final expr = compileFuzzy(
        const AnalyzerTokens(lexical: ['hello', 'world']),
        maxVariants: 5,
      )!;
      expect(expr, startsWith('"hello" AND ('));
      expect(expr, isNot(contains('"helo"*'))); // hello 退回精确
      expect(expr, contains('"world"*')); // 末词元仍扩展
    });

    test('scope=metadata：对整个模糊表达式施加列过滤', () {
      final expr = compileFuzzy(
        const AnalyzerTokens(lexical: ['helo']),
        scope: LocalSearchScope.metadata,
      )!;
      expect(
        expr,
        startsWith('{title_tok artist_tok album_tok filename_tok pinyin_tok} : ('),
      );
    });
  });

  group('跨语言第 4 支（T1 crossLingual）', () {
    test('空 crossLingual 不加分支（向后兼容）', () {
      expect(compileMatch(const AnalyzerTokens(lexical: ['love'])), '"love"*');
      expect(compileMatch(const AnalyzerTokens(crossLingual: ['', '  '])), isNull);
    });

    test('单候选：裸加引号', () {
      expect(compileMatch(const AnalyzerTokens(crossLingual: ['爱'])), '"爱"');
    });

    test('多候选：候选之间 OR（非 AND），整体加括号', () {
      expect(
        compileMatch(const AnalyzerTokens(crossLingual: ['爱', '恋', '疼'])),
        '("爱" OR "恋" OR "疼")',
      );
    });

    test('与其它分支 OR 组合（英文词 + 候选汉字）', () {
      // AnalyzeQuery('love')：lexical=love、crossLingual=喜/恋/爱…
      expect(
        compileMatch(const AnalyzerTokens(
          lexical: ['love'],
          crossLingual: ['爱', '恋'],
        )),
        '("love"* OR ("爱" OR "恋"))',
      );
    });

    test('scope=metadata：候选纳入列过滤括号内', () {
      expect(
        compileMatch(
          const AnalyzerTokens(lexical: ['love'], crossLingual: ['爱', '恋']),
          scope: LocalSearchScope.metadata,
        ),
        '{title_tok artist_tok album_tok filename_tok pinyin_tok} : '
        '("love"* OR ("爱" OR "恋"))',
      );
    });

    test('转义安全：候选含引号按字面量转义', () {
      expect(
        compileMatch(const AnalyzerTokens(crossLingual: ['a"b', 'c'])),
        '("a""b" OR "c")',
      );
      expect(
        compileMatch(const AnalyzerTokens(crossLingual: ['a"b'])),
        '"a""b"',
      );
    });

    test('不加前缀 *（候选为完整词 / 字，避免过度召回）', () {
      final expr = compileMatch(const AnalyzerTokens(crossLingual: ['爱', 'love']))!;
      expect(expr, isNot(contains('*')));
    });
  });
}
