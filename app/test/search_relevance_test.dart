// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 聚合搜索匹配度排序单测。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/utils/search_relevance.dart';

void main() {
  test('标题全等 > 前缀 > 包含 > 无关', () {
    final exact = searchRelevanceScore('晴天', '晴天', '周杰伦');
    final prefix = searchRelevanceScore('晴天', '晴天娃娃', '');
    final contains = searchRelevanceScore('晴天', '我的晴天', '');
    final unrelated = searchRelevanceScore('晴天', '阴天', '');
    expect(exact, greaterThan(prefix));
    expect(prefix, greaterThan(contains));
    expect(contains, greaterThan(unrelated));
  });

  test('歌手命中提升相关度', () {
    final withArtist = searchRelevanceScore('周杰伦 晴天', '晴天', '周杰伦');
    final otherArtist = searchRelevanceScore('周杰伦 晴天', '晴天', '蔡依林');
    expect(withArtist, greaterThan(otherArtist));
  });

  test('原唱优先：版本/翻唱降权（Live/伴奏/翻唱）', () {
    final original = searchRelevanceScore('晴天', '晴天', '周杰伦');
    final live = searchRelevanceScore('晴天', '晴天 (Live)', '周杰伦');
    final cover = searchRelevanceScore('晴天', '晴天 (翻唱)', '张三');
    final inst = searchRelevanceScore('晴天', '晴天 (伴奏)', '周杰伦');
    expect(original, greaterThan(live));
    expect(original, greaterThan(cover));
    expect(original, greaterThan(inst));
  });

  test('空查询 → 0', () {
    expect(searchRelevanceScore('', '晴天', '周杰伦'), 0);
    expect(searchRelevanceScore('   ', '晴天', '周杰伦'), 0);
  });

  test('sortByRelevance：跨来源按匹配度重排', () {
    // 模拟三平台结果：同曲不同来源，另有一条弱相关。
    final items = [
      ('kugou', '晴天', '周杰伦'),
      ('netease', '晴天', '周杰伦'),
      ('kugou', '阴天', '莫文蔚'),
      ('qqmusic', '晴天 (Live)', '周杰伦'),
    ];
    final sorted = sortByRelevance(
      '周杰伦 晴天',
      items,
      (e) => searchRelevanceScore('周杰伦 晴天', e.$2, e.$3),
    );
    // 前两位应是标题全等的「晴天」，弱相关的「阴天」垫底。
    expect(sorted.first.$2, '晴天');
    expect(sorted.last.$2, '阴天');
  });

  test('sortByRelevance：同分保持原顺序（稳定）', () {
    final items = ['b', 'a', 'c'];
    final sorted = sortByRelevance<String>('q', items, (_) => 1);
    expect(sorted, items);
  });

  test('歌名查询：不因歌手名更长而把原唱降权（回归）', () {
    // 三拜红尘凉：原唱尹昔眠（3 字）vs 翻唱黄龄/酒禾（2 字），歌名全等时
    // 三者相关度应一致，不得让短歌手名压过原唱。
    final original = searchRelevanceScore('三拜红尘凉', '三拜红尘凉', '尹昔眠');
    final cover = searchRelevanceScore('三拜红尘凉', '三拜红尘凉', '黄龄');
    expect(original, equals(cover));
  });

  test('歌名查询：同分下保留各源原生名次（原唱在各源首位则仍居首）', () {
    final items = [
      ('netease', '三拜红尘凉', '尹昔眠'),
      ('netease', '三拜红尘凉', '黄龄'),
      ('kugou', '三拜红尘凉', '尹昔眠'),
      ('qqmusic', '三拜红尘凉', '酒禾'),
    ];
    final sorted = sortByRelevance(
      '三拜红尘凉',
      items,
      (e) => searchRelevanceScore('三拜红尘凉', e.$2, e.$3),
    );
    expect(sorted.first.$3, '尹昔眠');
  });
}
