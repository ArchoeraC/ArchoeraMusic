/// 聚合搜索「各源独立容错 + 失败退避」纯逻辑测试（不联网）。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/netease/netease_api.dart';
import 'package:archoera_music/widgets/search/search_source_state.dart';

SearchResult<String> _ok(List<String> items) =>
    SearchResult(items: items, total: items.length, hasMore: false);

void main() {
  group('fetchSourcesIndependently 各源独立', () {
    test('一源失败不阻断其它源；错误带 source 与原因', () async {
      final attempts = await fetchSourcesIndependently<String>(
        const ['netease', 'kugou', 'qqmusic'],
        (source) async {
          if (source == 'qqmusic') throw Exception('QQ 风控 inner=2001');
          return _ok(['a-$source', 'b-$source']);
        },
      );

      expect(attempts, hasLength(3));
      final qq = attempts.singleWhere((a) => a.source == 'qqmusic');
      expect(qq.ok, isFalse);
      expect(qq.error, isA<Exception>());
      expect('${qq.error}', contains('2001'));
      for (final ok in attempts.where((a) => a.source != 'qqmusic')) {
        expect(ok.ok, isTrue);
        expect(ok.result!.items, hasLength(2));
      }
    });

    test('全部失败也各自成条目而非整体抛错', () async {
      final attempts = await fetchSourcesIndependently<String>(
        const ['netease', 'qqmusic'],
        (source) async => throw StateError('down'),
      );
      expect(attempts.every((a) => !a.ok && a.source.isNotEmpty), isTrue);
    });

    test('全部成功则都 ok', () async {
      final attempts = await fetchSourcesIndependently<String>(
        const ['netease', 'kugou'],
        (source) async => _ok([source]),
      );
      expect(attempts.every((a) => a.ok), isTrue);
    });
  });

  group('SearchSourceCooldown 失败退避', () {
    final t0 = DateTime(2026, 1, 1, 12, 0, 0);
    final cooldown = SearchSourceCooldown(
      cooldown: const Duration(seconds: 20),
    );

    test('失败后冷却期内禁止重试，超时后放行', () {
      cooldown.markFailed('qqmusic', now: t0);
      expect(cooldown.cooling('qqmusic', now: t0), isTrue);
      expect(cooldown.cooling('qqmusic', now: t0.add(const Duration(seconds: 5))), isTrue);
      expect(cooldown.remaining('qqmusic', now: t0), const Duration(seconds: 20));
      // 20s 整可重试（>= 冷却）
      expect(
        cooldown.cooling('qqmusic', now: t0.add(const Duration(seconds: 20))),
        isFalse,
      );
    });

    test('clear 后立即可重试；未失败来源不受冷却影响', () {
      expect(cooldown.cooling('netease', now: t0), isFalse);
      cooldown.markFailed('qqmusic', now: t0);
      cooldown.clear('qqmusic');
      expect(cooldown.cooling('qqmusic', now: t0), isFalse);
    });
  });
}
