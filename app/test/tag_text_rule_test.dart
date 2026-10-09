// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 标签文本规则纯逻辑单测（`services/scraper/tag_text_rule.dart`）。
///
/// 覆盖：不修改 / 查找替换（区分与不区分大小写）/ 正则（含反向引用与非法
/// 正则）/ 前缀与后缀（含 [index] 等占位符）/ 占位符取值表。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/scraper/tag_editor_service.dart';
import 'package:archoera_music/services/scraper/tag_text_rule.dart';
import 'package:archoera_music/widgets/common/tag_text_rule_editor.dart';

void main() {
  group('applyTagTextOp - none/prefix/suffix', () {
    test('none 原样返回', () {
      expect(
        applyTagTextOp(
          op: TagTextOp.none,
          input: 'Hello',
          find: 'x',
          replace: 'y',
          affix: 'z',
          vars: const {},
        ),
        'Hello',
      );
    });

    test('prefix 支持 [index] 占位符', () {
      expect(
        applyTagTextOp(
          op: TagTextOp.prefix,
          input: 'Title',
          find: '',
          replace: '',
          affix: '[index]. ',
          vars: const {'index': '3'},
        ),
        '3. Title',
      );
    });

    test('suffix 支持 [title] 与 [artist] 占位符', () {
      expect(
        applyTagTextOp(
          op: TagTextOp.suffix,
          input: 'Song',
          find: '',
          replace: '',
          affix: ' - [artist] ([year])',
          vars: const {'artist': 'A', 'year': '2020'},
        ),
        'Song - A (2020)',
      );
    });

    test('未知占位符保持原样', () {
      expect(
        applyTagTextOp(
          op: TagTextOp.suffix,
          input: 'X',
          find: '',
          replace: '',
          affix: ' [nope]',
          vars: const {'index': '1'},
        ),
        'X [nope]',
      );
    });
  });

  group('applyTagTextOp - findReplace', () {
    test('默认区分大小写', () {
      expect(
        applyTagTextOp(
          op: TagTextOp.findReplace,
          input: 'Hello World',
          find: 'o',
          replace: '0',
          affix: '',
          vars: const {},
        ),
        'Hell0 W0rld',
      );
    });

    test('不区分大小写', () {
      expect(
        applyTagTextOp(
          op: TagTextOp.findReplace,
          input: 'Hello World',
          find: 'h',
          replace: 'J',
          affix: '',
          vars: const {},
          caseSensitive: false,
        ),
        'Jello World',
      );
    });

    test('find 为空时不变', () {
      expect(
        applyTagTextOp(
          op: TagTextOp.findReplace,
          input: 'Hello',
          find: '',
          replace: 'X',
          affix: '',
          vars: const {},
        ),
        'Hello',
      );
    });

    test('正则 + 反向引用', () {
      expect(
        applyTagTextOp(
          op: TagTextOp.findReplace,
          input: 'Hello World',
          find: r'(\w+) (\w+)',
          replace: r'$2 $1',
          affix: '',
          vars: const {},
          regex: true,
        ),
        'World Hello',
      );
    });

    test('正则不区分大小写', () {
      expect(
        applyTagTextOp(
          op: TagTextOp.findReplace,
          input: 'abc ABC',
          find: 'abc',
          replace: 'X',
          affix: '',
          vars: const {},
          regex: true,
          caseSensitive: false,
        ),
        'X X',
      );
    });

    test('非法正则：原样返回（不抛异常）', () {
      expect(
        applyTagTextOp(
          op: TagTextOp.findReplace,
          input: 'Hello',
          find: '(',
          replace: 'X',
          affix: '',
          vars: const {},
          regex: true,
        ),
        'Hello',
      );
    });
  });

  group('tagTextVars / resolveTagTokens', () {
    test('字段映射与空值处理', () {
      final vars = tagTextVars(
        TrackTags(
          title: 'T',
          artist: 'A',
          album: 'Al',
          albumArtist: 'AA',
          trackNumber: 7,
          discNumber: 0,
          year: 2024,
        ),
        2,
      );
      expect(vars['index'], '2');
      expect(vars['track'], '7');
      expect(vars['disc'], ''); // 0 → 空
      expect(vars['title'], 'T');
      expect(vars['artist'], 'A');
      expect(vars['album'], 'Al');
      expect(vars['albumartist'], 'AA');
      expect(vars['year'], '2024');
    });

    test('resolveTagTokens 无占位符时快速返回', () {
      expect(resolveTagTokens('plain', const {'index': '1'}), 'plain');
    });
  });

  group('tagTextRulePresets', () {
    TagTextRulePreset preset(String id) =>
        tagTextRulePresets.firstWhere((p) => p.id == id);

    test('trim：去除首尾空白', () {
      expect(preset('trim').snapshot.apply('  Hello  ', const {}), 'Hello');
    });

    test('stripBrackets：去除结尾括号标注', () {
      expect(
        preset('stripBrackets').snapshot.apply('Song (Live)', const {}),
        'Song',
      );
    });

    test('stripLive：不区分大小写', () {
      expect(
        preset('stripLive').snapshot.apply('Song (LIVE)', const {}),
        'Song',
      );
    });

    test('stripFeat：去除 feat. 之后内容', () {
      expect(preset('stripFeat').snapshot.apply('A feat. B', const {}), 'A');
    });

    test('indexSuffix：追加 [index] 后缀', () {
      expect(
        preset('indexSuffix').snapshot.apply('Song', const {'index': '3'}),
        'Song 3',
      );
    });
  });

  group('TagTextRulePreset 序列化', () {
    test('toStored / fromStored 往返', () {
      final p = TagTextRulePreset(
        id: 'custom:x',
        customName: 'x',
        label: (_) => 'x',
        op: TagTextOp.findReplace,
        find: 'a',
        replace: 'b',
        regex: true,
        caseSensitive: false,
      );
      final stored = p.toStored('My Rule');
      expect(stored['name'], 'My Rule');
      expect(stored['op'], 'findReplace');

      final back = TagTextRulePreset.fromStored(stored);
      expect(back.customName, 'My Rule');
      expect(back.op, TagTextOp.findReplace);
      expect(back.find, 'a');
      expect(back.replace, 'b');
      expect(back.regex, isTrue);
      expect(back.caseSensitive, isFalse);
      expect(back.snapshot.apply('xax', const {}), 'xbx');
    });

    test('fromStored 容忍未知 op / 缺失字段', () {
      final back = TagTextRulePreset.fromStored(const {'name': 'n'});
      expect(back.op, TagTextOp.none);
      expect(back.caseSensitive, isTrue);
      expect(back.regex, isFalse);
    });
  });

  group('computeTextDiff', () {
    test('无差异', () {
      final d = computeTextDiff('abc', 'abc');
      expect(d.changed, isFalse);
      expect(d.prefix, 'abc');
      expect(d.removed, '');
      expect(d.added, '');
      expect(d.suffix, '');
    });

    test('末尾新增（后缀场景）', () {
      final d = computeTextDiff('Hello', 'Hello World');
      expect(d.changed, isTrue);
      expect(d.prefix, 'Hello');
      expect(d.added, ' World');
      expect(d.removed, '');
      expect(d.suffix, '');
    });

    test('开头新增（前缀场景）', () {
      final d = computeTextDiff('World', 'Hello World');
      expect(d.prefix, '');
      expect(d.added, 'Hello ');
      expect(d.removed, '');
      expect(d.suffix, 'World');
    });

    test('中段替换', () {
      final d = computeTextDiff('Hello World', 'Hello There');
      expect(d.prefix, 'Hello ');
      expect(d.removed, 'World');
      expect(d.added, 'There');
      expect(d.suffix, '');
    });

    test('删除中段', () {
      final d = computeTextDiff('abc123', 'abc');
      expect(d.prefix, 'abc');
      expect(d.removed, '123');
      expect(d.added, '');
    });

    test('空 → 非空', () {
      final d = computeTextDiff('', 'X');
      expect(d.prefix, '');
      expect(d.removed, '');
      expect(d.added, 'X');
    });

    test('非空 → 空', () {
      final d = computeTextDiff('X', '');
      expect(d.prefix, '');
      expect(d.removed, 'X');
      expect(d.added, '');
    });
  });

  group('movePresetEntry', () {
    List<Map<String, dynamic>> sample() => [
      {'name': 'a'},
      {'name': 'b'},
      {'name': 'c'},
    ];

    test('上移', () {
      final r = movePresetEntry(sample(), 1, -1);
      expect(r.map((m) => m['name']), ['b', 'a', 'c']);
    });

    test('下移', () {
      final r = movePresetEntry(sample(), 0, 1);
      expect(r.map((m) => m['name']), ['b', 'a', 'c']);
    });

    test('越界不变且返回副本（不改原列表）', () {
      final src = sample();
      final up = movePresetEntry(src, 0, -1);
      final down = movePresetEntry(src, 2, 1);
      expect(up.map((m) => m['name']), ['a', 'b', 'c']);
      expect(down.map((m) => m['name']), ['a', 'b', 'c']);
      expect(identical(up, src), isFalse);
      expect(src.map((m) => m['name']), ['a', 'b', 'c']);
    });
  });

  group('renamePresetEntry', () {
    test('基本改名保留顺序', () {
      final r = renamePresetEntry(
        [
          {'name': 'a'},
          {'name': 'b'},
        ],
        'a',
        'z',
      );
      expect(r.map((m) => m['name']), ['z', 'b']);
    });

    test('与既有同名时合并为一项', () {
      final r = renamePresetEntry(
        [
          {'name': 'a'},
          {'name': 'b'},
        ],
        'a',
        'b',
      );
      expect(r.length, 1);
      expect(r.map((m) => m['name']), ['b']);
    });

    test('同名 / 缺失原名时不变（返回副本）', () {
      final src = [
        {'name': 'a'},
      ];
      expect(renamePresetEntry(src, 'a', 'a').map((m) => m['name']), ['a']);
      final miss = renamePresetEntry(src, 'x', 'y');
      expect(miss.map((m) => m['name']), ['a']);
      expect(identical(miss, src), isFalse);
    });
  });
}
