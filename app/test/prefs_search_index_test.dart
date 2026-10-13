// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/stores/app_prefs.dart';

/// 本地曲库搜索索引偏好（总开关 / `.lrc` 子开关）默认值与写入。
void main() {
  group('本地搜索索引开关（默认关，设计文档 §2.4）', () {
    test('默认：总开关关、.lrc 子开关关', () {
      final prefs = AppPrefs();
      expect(prefs.enableLocalSearchIndex, isFalse);
      expect(prefs.indexLrc, isFalse);
    });

    test('copyWithSearchIndex 读写总开关', () {
      final on = AppPrefs().copyWithSearchIndex(enabled: true);
      expect(on.enableLocalSearchIndex, isTrue);
      expect(on.indexLrc, isFalse, reason: '未传 indexLrc 时不受影响');
      final off = on.copyWithSearchIndex(enabled: false);
      expect(off.enableLocalSearchIndex, isFalse);
    });

    test('copyWithSearchIndex 读写 .lrc 子开关', () {
      final prefs = AppPrefs().copyWithSearchIndex(enabled: true, indexLrc: true);
      expect(prefs.enableLocalSearchIndex, isTrue);
      expect(prefs.indexLrc, isTrue);
    });

    test('copyWithSearchIndex 往返：未传字段保持不变', () {
      final on = AppPrefs().copyWithSearchIndex(enabled: true, indexLrc: true);
      final same = on.copyWithSearchIndex();
      expect(same.enableLocalSearchIndex, isTrue);
      expect(same.indexLrc, isTrue);
      // 关总开关不应清空 .lrc 子开关（子开关值独立保留；UI 侧仅在总开关
      // 开启时可用，见 search_section_test）。
      final off = on.copyWithSearchIndex(enabled: false);
      expect(off.enableLocalSearchIndex, isFalse);
      expect(off.indexLrc, isTrue);
    });

    test('键值语义（search.index.*）', () {
      expect(enableLocalSearchIndexKey, 'search.index.enabled');
      expect(indexLrcKey, 'search.index.lrc');
      final prefs = AppPrefs(initialData: {
        enableLocalSearchIndexKey: true,
        indexLrcKey: true,
      });
      expect(prefs.enableLocalSearchIndex, isTrue);
      expect(prefs.indexLrc, isTrue);
    });

    test('非法值回退默认关', () {
      final prefs = AppPrefs(initialData: {
        enableLocalSearchIndexKey: 'yes',
        indexLrcKey: 1,
      });
      expect(prefs.enableLocalSearchIndex, isFalse);
      expect(prefs.indexLrc, isFalse);
    });

    test('与搜索历史共存（互不影响）', () {
      final prefs = AppPrefs()
          .copyWithSearchHistory(const ['周杰伦'])
          .copyWithSearchIndex(enabled: true);
      expect(prefs.enableLocalSearchIndex, isTrue);
      expect(prefs.searchHistory, const ['周杰伦']);
    });
  });
}
