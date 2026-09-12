// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 解锁脏话（语义化重建）单元测试。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/lyrics/profanity.dart';

void main() {
  group('unmaskProfanity 模式重建', () {
    test('常见遮盖形态还原为原词', () {
      expect(unmaskProfanity('f**k'), 'fuck');
      expect(unmaskProfanity('s**t'), 'shit');
      expect(unmaskProfanity('sh*t'), 'shit');
      expect(unmaskProfanity('sh**'), 'shit');
      expect(unmaskProfanity('b***h'), 'bitch');
      expect(unmaskProfanity('c**t'), 'cunt');
      expect(unmaskProfanity('c**k'), 'cock');
      expect(unmaskProfanity('co**'), 'cock');
      expect(unmaskProfanity('d**k'), 'dick');
      expect(unmaskProfanity('d**n'), 'damn');
      expect(unmaskProfanity('as*'), 'ass');
      expect(unmaskProfanity('a**hole'), 'asshole');
      expect(unmaskProfanity('a**'), 'ass');
      expect(unmaskProfanity('w***e'), 'whore');
      expect(unmaskProfanity('n***a'), 'nigga');
      expect(unmaskProfanity('s**ker'), 'sucker');
      expect(unmaskProfanity('f**king'), 'fucking');
      expect(unmaskProfanity('motherf***er'), 'motherfucker');
    });

    test('星号段代表整块内容（变长遮罩）', () {
      expect(unmaskProfanity('as**le'), 'asshole');
      expect(unmaskProfanity('a**hole'), 'asshole');
      expect(unmaskProfanity('m*therf*cker'), 'motherfucker');
    });

    test('同一模式多候选时取更常见者', () {
      // s??t 同时匹配 shit / slut，词典顺序取 shit。
      expect(unmaskProfanity('s**t'), 'shit');
    });

    test('保留原片段大小写', () {
      expect(unmaskProfanity('F**k'), 'Fuck');
      expect(unmaskProfanity('F**K'), 'FUCK');
      expect(unmaskProfanity('S**t happens'), 'Shit happens');
    });

    test('嵌入句子 / 标点 / 逐字片段', () {
      expect(unmaskProfanity('What the f**k!'), 'What the fuck!');
      expect(unmaskProfanity('no sh*t, really?'), 'no shit, really?');
      expect(unmaskProfanity('b***h!'), 'bitch!');
    });

    test('歧义或非脏话保持原样', () {
      expect(unmaskProfanity('****'), '****');
      expect(unmaskProfanity('h***o'), 'h***o'); // hello 不在词典
      expect(unmaskProfanity('blah blah'), 'blah blah');
      expect(unmaskProfanity(''), '');
      expect(unmaskProfanity('no stars here'), 'no stars here');
    });

    test('幂等：还原结果再次调用不变', () {
      expect(unmaskProfanity('fuck'), 'fuck');
      expect(unmaskProfanity(unmaskProfanity('What the f**k')), 'What the fuck');
    });
  });

  group('unmaskProfanity 增强：遮盖符与词典', () {
    test('全角 / 异体遮盖符', () {
      expect(unmaskProfanity('f＊＊k'), 'fuck');
      expect(unmaskProfanity('s＊＊t'), 'shit');
      expect(unmaskProfanity('f××k'), 'fuck');
      expect(unmaskProfanity('b＊＊＊h'), 'bitch');
      expect(unmaskProfanity('f∗∗k'), 'fuck'); // U+2217
      expect(unmaskProfanity('f✱✱k'), 'fuck'); // U+2731
    });

    test('全角英数字归一化', () {
      expect(unmaskProfanity('ｆ＊ｃｋ'), 'fuck');
      expect(unmaskProfanity('Ｆ＊＊Ｋ'), 'FUCK');
    });

    test('扩充词典', () {
      expect(unmaskProfanity('b*llocks'), 'bollocks');
      expect(unmaskProfanity('t*sser'), 'tosser');
      expect(unmaskProfanity('w*nker'), 'wanker');
      expect(unmaskProfanity('n*ghtcore'), 'n*ghtcore'); // 非脏话保持原样
    });
  });
}
