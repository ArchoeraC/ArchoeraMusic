// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/search/search_models.dart';
import 'package:archoera_music/services/search/search_query.dart';

/// FTS5 `MATCH` 表达式编译的**纯单测**（无 FFI / 无 DB）。
///
/// 覆盖：中文子串（bigram+unigram）、**连续 bigram 引号短语**（P4）、拼音（**≥2 音节相邻
/// 短语**，P5 实测修订）、**首字母独立列 + 列过滤**（P5 实测修订）、**前缀长度门控**、
/// **跨语言支的渐进兜底**（T1）、scope 列过滤，以及特殊字符（`"` / `*` / `(` / `:`）
/// 的转义安全与空输入。
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

    test('拼音：≥2 音节编译为「位置相邻短语」+ 列过滤到拼音两列（v4）', () {
      final expr = compileMatch(const AnalyzerTokens(pinyin: ['wo', 'ai', 'ni']));
      expect(expr, '{pinyin_meta_tok pinyin_lyrics_tok} : ' + '"wo ai ni"');
    });

    test('拼音：单音节 3 字符起加前缀，1–2 字符精确（前缀长度门控）', () {
      expect(compileMatch(const AnalyzerTokens(pinyin: ['hao'])), '{pinyin_meta_tok pinyin_lyrics_tok} : ' + '"hao"*');
      // 2 字符前缀（"wo"* / "ni"*）会把命中集放大到近乎整库 → 精确匹配
      expect(compileMatch(const AnalyzerTokens(pinyin: ['wo'])), '{pinyin_meta_tok pinyin_lyrics_tok} : ' + '"wo"');
      expect(compileMatch(const AnalyzerTokens(pinyin: ['ni'])), '{pinyin_meta_tok pinyin_lyrics_tok} : ' + '"ni"');
      expect(compileMatch(const AnalyzerTokens(pinyin: ['w'])), '{pinyin_meta_tok pinyin_lyrics_tok} : ' + '"w"');
    });

    test('拼音：双音节同样是短语（不再有首音节前缀变体）', () {
      expect(compileMatch(const AnalyzerTokens(pinyin: ['w', 'ai'])), '{pinyin_meta_tok pinyin_lyrics_tok} : ' + '"w ai"');
      expect(compileMatch(const AnalyzerTokens(pinyin: ['wo', 'ai'])), '{pinyin_meta_tok pinyin_lyrics_tok} : ' + '"wo ai"');
    });

    test('首字母：列过滤到首字母两列（v4），2 字符起加前缀', () {
      expect(
        compileMatch(const AnalyzerTokens(initials: 'wan')),
        '({initials_meta_tok initials_lyrics_tok} : "wan"*)',
      );
      expect(
        compileMatch(const AnalyzerTokens(initials: 'zjl')),
        '({initials_meta_tok initials_lyrics_tok} : "zjl"*)',
      );
      // 1 字符首字母不加前缀（列空间虽小，仍避免 `"a"*` 这类无差别命中）
      expect(
        compileMatch(const AnalyzerTokens(initials: 'a')),
        '({initials_meta_tok initials_lyrics_tok} : "a")',
      );
      // 多段（空格分隔）逐段 AND，末段前缀
      expect(
        compileMatch(const AnalyzerTokens(initials: 'wan zjl')),
        '({initials_meta_tok initials_lyrics_tok} : "wan" AND "zjl"*)',
      );
    });

    test('拉丁/数字：末 token 3 字符起前缀，非末 token 不加', () {
      expect(
        compileMatch(const AnalyzerTokens(lexical: ['love'])),
        '"love"*',
      );
      expect(
        compileMatch(const AnalyzerTokens(lexical: ['love', 'song'])),
        '"love" AND "song"*',
      );
      // 2 字符拉丁词不前缀（如 `ab` 会命中所有 ab* 词）
      expect(compileMatch(const AnalyzerTokens(lexical: ['ab'])), '"ab"');
    });

    test('各支以 OR 组合（任一层命中即召回）', () {
      final expr = compileMatch(const AnalyzerTokens(
        lexical: ['abc'],
        pinyin: ['hao'],
        initials: 'wan',
      ));
      expect(
        expr,
        '("abc"* OR {pinyin_meta_tok pinyin_lyrics_tok} : ' + '"hao"* OR ({initials_meta_tok initials_lyrics_tok} : "wan"*))',
      );
    });

    test('连写全拼（分析器切分后）编译：woaini → 词法支 + 拼音短语支', () {
      // AnalyzeQuery('woaini') 的原生输出：lexical=woaini、pinyin=wo ai ni、initials=null。
      final expr = compileMatch(const AnalyzerTokens(
        lexical: ['woaini'],
        pinyin: ['wo', 'ai', 'ni'],
      ));
      expect(
        expr,
        '("woaini"* OR {pinyin_meta_tok pinyin_lyrics_tok} : ' + '"wo ai ni")',
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
        '{title_tok artist_tok album_tok filename_tok pinyin_meta_tok initials_meta_tok reading_meta_tok} : '
        '("love" AND "song"*)',
      );
    });

    test('metadata：多支 OR 整体加括号过滤', () {
      final expr = compileMatch(
        const AnalyzerTokens(
            lexical: ['love'], pinyin: ['hao'], initials: 'wan'),
        scope: LocalSearchScope.metadata,
      );
      expect(
        expr,
        '{title_tok artist_tok album_tok filename_tok pinyin_meta_tok initials_meta_tok reading_meta_tok} : '
        '("love"* OR {pinyin_meta_tok pinyin_lyrics_tok} : "hao"* '
        'OR ({initials_meta_tok initials_lyrics_tok} : "wan"*))',
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
        '"a""b" AND "a*b" AND "(" AND ":"',
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

    test('首字母串含引号 / 空格：仍按字面量转义（列过滤不破）', () {
      expect(
        compileMatch(const AnalyzerTokens(initials: 'a"b')),
        '({initials_meta_tok initials_lyrics_tok} : "a""b"*)',
      );
    });
  });

  group('compileReading 日文读音（v5，兜底趟）', () {
    test('拉丁词元 → 字母 bigram **短语**（相邻 = 子串语义），列过滤到读音两列', () {
      expect(
        compileReading(const AnalyzerTokens(lexical: ['kurarin'])),
        '{$readingColumns} : ("ku ur ra ar ri in")',
      );
      // 多词元：各自短语之间 AND
      expect(
        compileReading(const AnalyzerTokens(lexical: ['yorushika', 'live'])),
        '{$readingColumns} : ("yo or ru us sh hi ik ka" AND "li iv ve")',
      );
    });

    test('汉字 / 假名词元不进读音支（主趟字符 bigram 已覆盖）；1 字符词元跳过', () {
      expect(compileReading(const AnalyzerTokens(lexical: ['くらりん'])), isNull);
      expect(compileReading(const AnalyzerTokens(lexical: ['初音'])), isNull);
      expect(compileReading(const AnalyzerTokens(lexical: ['a'])), isNull);
      expect(compileReading(const AnalyzerTokens()), isNull);
    });

    test('scope=metadata 时用元数据白名单（含 reading_meta_tok）', () {
      final expr = compileReading(const AnalyzerTokens(lexical: ['yone']),
          scope: LocalSearchScope.metadata);
      expect(
        expr,
        '{title_tok artist_tok album_tok filename_tok pinyin_meta_tok initials_meta_tok reading_meta_tok} : '
        '("yo on ne")',
      );
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
        startsWith('{title_tok artist_tok album_tok filename_tok pinyin_meta_tok initials_meta_tok reading_meta_tok} : ('),
      );
    });
  });

  group('跨语言第 4 支（T1 crossLingual，渐进兜底）', () {
    test('默认不并入主表达式（避免每次都付整库级代价）', () {
      expect(
        compileMatch(const AnalyzerTokens(
          lexical: ['love'],
          crossLingual: ['爱', '恋'],
        )),
        '"love"*',
      );
    });

    test('includeCrossLingual：并入主表达式（旧行为，供显式使用）', () {
      expect(
        compileMatch(
          const AnalyzerTokens(lexical: ['love'], crossLingual: ['爱', '恋']),
          includeCrossLingual: true,
        ),
        '("love"* OR ("爱" OR "恋"))',
      );
      // 仅有跨语言候选时，并入后即为全部内容；不并入则为 null（无可用支）
      expect(compileMatch(const AnalyzerTokens(crossLingual: ['爱'])), isNull);
      expect(
        compileMatch(const AnalyzerTokens(crossLingual: ['爱']),
            includeCrossLingual: true),
        '"爱"',
      );
    });

    test('compileCrossLingual：单独成趟（第二趟用），无候选返回 null', () {
      expect(
        compileCrossLingual(const AnalyzerTokens(crossLingual: ['爱', '恋', '疼'])),
        '("爱" OR "恋" OR "疼")',
      );
      expect(
        compileCrossLingual(const AnalyzerTokens(crossLingual: ['爱'])),
        '"爱"',
      );
      expect(
        compileCrossLingual(const AnalyzerTokens(crossLingual: ['', '  '])),
        isNull,
      );
      expect(compileCrossLingual(const AnalyzerTokens(lexical: ['love'])), isNull);
    });

    test('compileCrossLingual：scope=metadata 时施加列过滤', () {
      expect(
        compileCrossLingual(
          const AnalyzerTokens(crossLingual: ['爱', '恋']),
          scope: LocalSearchScope.metadata,
        ),
        '{title_tok artist_tok album_tok filename_tok pinyin_meta_tok initials_meta_tok reading_meta_tok} : '
        '("爱" OR "恋")',
      );
    });

    test('转义安全：候选含引号按字面量转义', () {
      expect(
        compileCrossLingual(const AnalyzerTokens(crossLingual: ['a"b', 'c'])),
        '("a""b" OR "c")',
      );
      expect(
        compileCrossLingual(const AnalyzerTokens(crossLingual: ['a"b'])),
        '"a""b"',
      );
    });

    test('不加前缀 *（候选为完整词 / 字，避免过度召回）', () {
      final expr =
          compileCrossLingual(const AnalyzerTokens(crossLingual: ['爱', 'love']))!;
      expect(expr, isNot(contains('*')));
    });
  });
}
