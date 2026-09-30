// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// [parseTtmlLyrics] / [parseTtmlTime] 回归测试（AMLL TTML，Apple 风格）。
///
/// 覆盖：真实样本（网易云 186016《晴天》62 行）、行时间推断、逐词片段
/// 与原文拼接不变量、译文语言择优、音译、背景人声行紧跟主行、时间解析。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/lyrics/lyric_line.dart';
import 'package:archoera_music/services/lyrics/ttml_parser.dart';

/// 拼接某组的逐词文本（无片段时返回空串）。
String joinedFragments(LyricGroup g) =>
    g.fragments == null ? '' : g.fragments!.map((f) => f.text).join();

/// 用一个最小 `<tt>` 外壳包裹给定的 `<p>` / `<div>` 内容。
String wrap(String body) =>
    '<tt xmlns="http://www.w3.org/ns/ttml" '
    'xmlns:ttm="http://www.w3.org/ns/ttml#metadata">'
    '<body><div>$body</div></body></tt>';

void main() {
  group('parseTtmlTime', () {
    test('无冒号：秒 → 毫秒（四舍五入）', () {
      expect(parseTtmlTime('1.234s'), 1234);
      expect(parseTtmlTime('0.5s'), 500);
      expect(parseTtmlTime('2s'), 2000);
      expect(parseTtmlTime('0'), 0);
    });

    test('mm:ss / hh:mm:ss，小数右补零到 3 位后截断', () {
      expect(parseTtmlTime('00:29.231'), 29231);
      expect(parseTtmlTime('01:02.003'), 62003);
      expect(parseTtmlTime('00:00.5'), 500);
      expect(parseTtmlTime('0:00.5'), 500);
      expect(parseTtmlTime('00:00.1234'), 123);
      expect(parseTtmlTime('1:02:03.5'), 3723500);
      expect(parseTtmlTime('01:02:03.250'), 3723250);
    });

    test('空串 / 非法 → 0', () {
      expect(parseTtmlTime(''), 0);
      expect(parseTtmlTime('   '), 0);
      expect(parseTtmlTime('abc'), 0);
    });
  });

  group('真实样本：网易云 186016《晴天》', () {
    late String ttml;

    setUpAll(() {
      ttml = File('test/fixtures/ttml/qingtian.ttml').readAsStringSync();
    });

    test('62 行，首行文本 / 时间 / 逐词片段正确', () {
      final groups = parseTtmlLyrics(ttml);
      expect(groups.length, 62);

      final first = groups.first;
      expect(first.original.text, '故事的小黄花');
      expect(first.original.timeMs, 29231);
      expect(first.isBG, isFalse);

      expect(first.fragments, isNotNull);
      expect(joinedFragments(first), '故事的小黄花');
      expect(first.fragments!.first.startMs, 0);
      expect(first.fragments!.first.durationMs, 461);
    });

    test('全部逐词行满足「拼接 == 原文」不变量', () {
      final groups = parseTtmlLyrics(ttml);
      for (final g in groups) {
        if (g.fragments == null) continue;
        expect(joinedFragments(g).trim(), g.original.text.trim());
        // 片段相对行首非负、时长非负。
        for (final f in g.fragments!) {
          expect(f.startMs, greaterThanOrEqualTo(0));
          expect(f.durationMs, greaterThanOrEqualTo(0));
        }
      }
    });

    test('整表按行时间升序', () {
      final groups = parseTtmlLyrics(ttml);
      for (var i = 1; i < groups.length; i++) {
        expect(
          groups[i].original.timeMs,
          greaterThanOrEqualTo(groups[i - 1].original.timeMs),
        );
      }
    });
  });

  group('译文语言择优', () {
    String withTranslations(String spans) => wrap(
          '<p begin="00:01.000" end="00:02.000">'
          '<span begin="00:01.000" end="00:02.000">Hello</span>$spans'
          '</p>',
        );

    test('规范化（大小写 / 下划线）后精确匹配优先', () {
      final ttml = withTranslations(
        '<span ttm:role="x-translation" xml:lang="en">英文</span>'
        '<span ttm:role="x-translation" xml:lang="zh_CN">简体</span>',
      );
      final g = parseTtmlLyrics(ttml, preferredLang: 'zh-CN').single;
      expect(g.translation, '简体');
    });

    test('无精确匹配时按基语言（- 前）匹配', () {
      final ttml = withTranslations(
        '<span ttm:role="x-translation" xml:lang="en">英文</span>'
        '<span ttm:role="x-translation" xml:lang="zh-TW">繁體</span>',
      );
      final g = parseTtmlLyrics(ttml, preferredLang: 'zh-CN').single;
      expect(g.translation, '繁體');
    });

    test('候选全无语言标签时取第一个', () {
      final ttml = withTranslations(
        '<span ttm:role="x-translation">第一</span>'
        '<span ttm:role="x-translation">第二</span>',
      );
      final g = parseTtmlLyrics(ttml).single;
      expect(g.translation, '第一');
    });

    test('有语言标签但都不匹配 → 无译文', () {
      final ttml = withTranslations(
        '<span ttm:role="x-translation" xml:lang="en">英文</span>'
        '<span ttm:role="x-translation" xml:lang="fr">法文</span>',
      );
      final g = parseTtmlLyrics(ttml, preferredLang: 'zh-CN').single;
      expect(g.translation, isNull);
    });

    test('lang（无 xml: 前缀）同样生效', () {
      final ttml = withTranslations(
        '<span ttm:role="x-translation" lang="ja">日本語</span>',
      );
      final g = parseTtmlLyrics(ttml, preferredLang: 'ja').single;
      expect(g.translation, '日本語');
    });
  });

  group('音译 / 背景人声', () {
    test('x-roman 取第一个', () {
      final ttml = wrap(
        '<p begin="00:01.000" end="00:02.000">'
        '<span begin="00:01.000" end="00:02.000">你好</span>'
        '<span ttm:role="x-roman">ni hao</span>'
        '<span ttm:role="x-roman">ni hao 2</span>'
        '</p>',
      );
      final g = parseTtmlLyrics(ttml).single;
      expect(g.romaji, 'ni hao');
    });

    test('x-bg 递归解析并紧跟主行，首尾圆括号剥离', () {
      final ttml = wrap(
        '<p begin="00:01.000" end="00:03.000">'
        '<span begin="00:01.000" end="00:02.000">主歌</span>'
        '<span ttm:role="x-bg">'
        '<span begin="00:01.000" end="00:01.200">（</span>'
        '<span begin="00:01.200" end="00:02.500">和声</span>'
        '<span begin="00:02.500" end="00:02.800">）</span>'
        '</span>'
        '</p>',
      );
      final groups = parseTtmlLyrics(ttml);
      expect(groups.length, 2);
      expect(groups[0].isBG, isFalse);
      expect(groups[0].original.text, '主歌');
      expect(groups[1].isBG, isTrue);
      expect(groups[1].original.text, '和声');
      // 背景行自身时间由内部计时词推断。
      expect(groups[1].original.timeMs, 1000);
      expect(groups[1].endMs, 2800);
      expect(joinedFragments(groups[1]), '和声');
    });

    test('背景行可含自己的译文', () {
      final ttml = wrap(
        '<p begin="00:01.000" end="00:03.000">'
        '<span begin="00:01.000" end="00:02.000">主歌</span>'
        '<span ttm:role="x-bg">'
        '<span begin="00:01.000" end="00:02.000">和声</span>'
        '<span ttm:role="x-translation" xml:lang="zh-CN">合声译</span>'
        '</span>'
        '</p>',
      );
      final groups = parseTtmlLyrics(ttml);
      expect(groups[1].isBG, isTrue);
      expect(groups[1].translation, '合声译');
    });
  });

  group('文本 / 片段不变量', () {
    test('未计时文本节点用行起止兜底，且拼接等于原文', () {
      final ttml = wrap(
        '<p begin="00:01.000" end="00:03.000">'
        '<span begin="00:01.000" end="00:02.000">Hello</span> world'
        '</p>',
      );
      final g = parseTtmlLyrics(ttml).single;
      expect(g.original.text, 'Hello world');
      expect(joinedFragments(g), 'Hello world');
      expect(g.fragments!.length, 2);
      expect(g.fragments![0].startMs, 0);
      expect(g.fragments![0].durationMs, 1000);
      expect(g.fragments![1].startMs, 0);
      expect(g.fragments![1].durationMs, 2000);
    });

    test('计时 span 之间的空白保留为一个 " " 词', () {
      final ttml = wrap(
        '<p begin="00:01.000" end="00:03.000">'
        '<span begin="00:01.000" end="00:01.800">Re</span>'
        ' <span begin="00:02.000" end="00:03.000">So</span>'
        '</p>',
      );
      final g = parseTtmlLyrics(ttml).single;
      expect(g.original.text, 'Re So');
      expect(g.fragments!.map((f) => f.text).toList(), ['Re', ' ', 'So']);
      expect(joinedFragments(g), 'Re So');
      final space = g.fragments![1];
      expect(space.startMs, 800);
      expect(space.durationMs, 200);
    });

    test('无计时 span 的行 fragments 为 null', () {
      final ttml = wrap('<p begin="00:01.000" end="00:02.000">纯文本行</p>');
      final g = parseTtmlLyrics(ttml).single;
      expect(g.original.text, '纯文本行');
      expect(g.original.timeMs, 1000);
      expect(g.fragments, isNull);
    });

    test('实体解码与 CDATA', () {
      final ttml = wrap(
        '<p begin="00:01.000" end="00:02.000">'
        'A &amp; B &#20320;&#x597D; <![CDATA[<raw>]]>'
        '</p>',
      );
      final g = parseTtmlLyrics(ttml).single;
      expect(g.original.text, 'A & B 你好 <raw>');
    });
  });

  group('行时间推断', () {
    test('缺 begin / end 时取计时词最小起 / 最大止', () {
      final ttml = wrap(
        '<p>'
        '<span begin="00:05.000" end="00:05.500">A</span>'
        '<span begin="00:05.500" end="00:07.000">B</span>'
        '</p>',
      );
      final g = parseTtmlLyrics(ttml).single;
      expect(g.original.timeMs, 5000);
      expect(g.endMs, 7000);
      expect(g.fragments!.first.startMs, 0);
      expect(g.fragments!.first.durationMs, 500);
      expect(g.fragments![1].startMs, 500);
      expect(g.fragments![1].durationMs, 1500);
    });
  });

  group('容错 / 边界', () {
    test('非 TTML 输入返回空列表且不抛异常', () {
      expect(parseTtmlLyrics(''), isEmpty);
      expect(parseTtmlLyrics('not xml at all'), isEmpty);
      expect(parseTtmlLyrics('<html><body><p>no tt</p></body></html>'),
          isEmpty);
    });

    test('无 <p> 的 TTML 返回空列表', () {
      expect(
        parseTtmlLyrics(
          '<tt xmlns="http://www.w3.org/ns/ttml"><body><div></div></body></tt>',
        ),
        isEmpty,
      );
    });

    test('注释 / 处理指令 / 自闭合标签可被跳过', () {
      final ttml =
          '<?xml version="1.0"?>'
          '<tt xmlns="http://www.w3.org/ns/ttml">'
          '<!-- a comment -->'
          '<head><metadata><amll:meta key="x" value="y"/></metadata></head>'
          '<body><div>'
          '<p begin="00:01.000" end="00:02.000">'
          '<span begin="00:01.000" end="00:02.000">行</span>'
          '</p>'
          '</div></body></tt>';
      final groups = parseTtmlLyrics(ttml);
      expect(groups.length, 1);
      expect(groups.single.original.text, '行');
    });

    test('preferredLang 不匹配但对端有基语言时仍能命中', () {
      final ttml = wrap(
        '<p begin="00:01.000" end="00:02.000">'
        '<span begin="00:01.000" end="00:02.000">x</span>'
        '<span ttm:role="x-translation" xml:lang="en-US">EN</span>'
        '</p>',
      );
      final g = parseTtmlLyrics(ttml, preferredLang: 'en-GB').single;
      expect(g.translation, 'EN');
    });
  });
}
