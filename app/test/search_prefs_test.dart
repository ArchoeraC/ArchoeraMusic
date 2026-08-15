import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/stores/app_prefs.dart';

void main() {
  group('searchHistory 搜索历史', () {
    test('默认空列表', () {
      final prefs = AppPrefs();
      expect(prefs.searchHistory, isEmpty);
    });

    test('copyWithSearchHistory 读写（保持顺序）', () {
      const history = ['周杰伦', '五月天', '周杰伦'];
      final prefs = AppPrefs().copyWithSearchHistory(history);
      expect(prefs.searchHistory, history);
      // 其余偏好不受影响
      expect(prefs.closeBehavior, defaultCloseBehavior);
    });

    test('非法值回退空列表', () {
      final prefs = AppPrefs(initialData: {searchHistoryKey: 42});
      expect(prefs.searchHistory, isEmpty);
      // 混入非字符串元素被过滤
      final mixed = AppPrefs(
        initialData: {searchHistoryKey: ['歌', 7, null, '曲']},
      );
      expect(mixed.searchHistory, ['歌', '曲']);
    });
  });
}
