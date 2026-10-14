// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 中文（CJK）查询容错的**变体生成纯单测**（无 FFI / 无 DB）。
///
/// 覆盖设计文档 `docs/local-search-index-plan.md` §4.6：CJK 子序列提取、
/// 编辑距离 ≤ 1（删除 / 相邻换位）、去重保序、预算截断、长度 / 非 CJK 边界。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/search/search_cjk_fuzzy.dart';

void main() {
  group('子串脚本范围（汉字 / 假名 / 谚文）', () {
    test('假名 / 谚文也算「需要子串索引」，故容错同样启用', () {
      expect(queryHasCjk('きゅうくらりん'), isTrue);
      expect(queryHasCjk('한국어노래'), isTrue);
      // 纯拉丁 / 数字仍为 false（走拉丁模糊趟）
      expect(queryHasCjk('hello'), isFalse);
    });

    test('isCjkCodeUnit 只认汉字（拼音高亮用）', () {
      expect(isCjkCodeUnit('周'.codeUnitAt(0)), isTrue);
      expect(isCjkCodeUnit('き'.codeUnitAt(0)), isFalse, reason: '假名没有拼音');
      expect(isIndexedScriptCodeUnit('き'.codeUnitAt(0)), isTrue);
    });
  });

  group('queryHasCjk', () {
    test('纯 CJK / 中英混合为真，纯拉丁为假', () {
      expect(queryHasCjk('周杰伦'), isTrue);
      expect(queryHasCjk('周伦'), isTrue);
      expect(queryHasCjk('周 abc 伦'), isTrue);
      expect(queryHasCjk('hello world'), isFalse);
      expect(queryHasCjk('123 456'), isFalse);
      expect(queryHasCjk(''), isFalse);
    });
  });

  group('cjkSubsequence', () {
    test('去非 CJK、保序', () {
      expect(cjkSubsequence('周杰伦'), '周杰伦');
      expect(cjkSubsequence('周 杰伦!'), '周杰伦');
      expect(cjkSubsequence('周abc伦'), '周伦');
      expect(cjkSubsequence('hello'), '');
      expect(cjkSubsequence(''), '');
    });
  });

  group('cjkVariants 删除 / 换位', () {
    test('两字：删除两字 + 一次换位（不含原串）', () {
      // 删除 i0→'伦'、i1→'周'；换位→'伦周'。
      expect(cjkVariants('周伦'), const ['伦', '周', '伦周']);
    });

    test('三字：删除全部 + 换位，且去重', () {
      // '我爱爱'：删除→'爱爱','我爱'（重复去掉）；换位 i0→'爱我爱'，i1 相同跳过。
      expect(cjkVariants('我爱爱'), const ['爱爱', '我爱', '爱我爱']);
    });

    test('混合查询只对 CJK 子序列生成变体', () {
      expect(cjkVariants('周abc伦'), cjkVariants('周伦'));
    });
  });

  group('cjkVariants 边界', () {
    test('单字 / 空 / 非 CJK 无变体', () {
      expect(cjkVariants('我'), isEmpty);
      expect(cjkVariants(''), isEmpty);
      expect(cjkVariants('hello'), isEmpty);
    });

    test('超长 CJK 查询放弃容错（长度硬上限）', () {
      final long = '一' * (maxCjkQueryLength + 1);
      expect(cjkVariants(long), isEmpty);
      // 恰好等于上限仍生成。
      expect(cjkVariants('一' * maxCjkQueryLength), isNotEmpty);
    });

    test('预算截断：变体数不超过 maxVariants', () {
      final long = '甲乙丙丁戊己庚辛壬癸' * 4; // 40 字
      final variants = cjkVariants(long, maxVariants: 5);
      expect(variants.length, 5);
    });

    test('相同字符对不产生无意义换位', () {
      // '一一'：无换位（相同）；删除两处均为 '一'（去重）→ 仅 ['一']。
      expect(cjkVariants('一一'), const ['一']);
    });
  });
}
