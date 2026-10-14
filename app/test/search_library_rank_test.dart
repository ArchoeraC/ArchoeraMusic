// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/scanner/library_search_rank.dart';
import 'package:archoera_music/services/search/search_models.dart';

/// 本地索引排行接入的**纯策略单测**（无 FFI / 无 DB）。
///
/// 覆盖：总开关关闭 / 空查询一律回退 `LIKE`；命中 → 有序 id；
/// 失败（null）→ 回退；真实空结果（[]）→ 不回退。
void main() {
  group('shouldUseSearchIndex（关闭 / 空查询即回退 LIKE）', () {
    test('总开关关闭：即使查询非空也走 LIKE', () {
      expect(shouldUseSearchIndex('周杰伦', false), isFalse);
    });

    test('总开关开启：查询非空才走索引', () {
      expect(shouldUseSearchIndex('周杰伦', true), isTrue);
    });

    test('空 / 纯空白查询：走 LIKE（等于原列表）', () {
      expect(shouldUseSearchIndex('', true), isFalse);
      expect(shouldUseSearchIndex('   ', true), isFalse);
    });
  });

  group('resolveRankedSearch（命中 → 有序 id；失败 → null 回退）', () {
    test('保持命中顺序', () async {
      final ids = await resolveRankedSearch(
        'q',
        (q, {int limit = kSearchIndexRankLimit}) async => const [
          LocalSearchHit(trackId: 't9', score: -9),
          LocalSearchHit(trackId: 't1', score: -3),
          LocalSearchHit(trackId: 't5', score: -1),
        ],
      );
      expect(ids, ['t9', 't1', 't5']);
    });

    test('search 返回 null（未开启 / 未就绪 / 失败）→ null 回退 LIKE', () async {
      final ids = await resolveRankedSearch(
        'q',
        (q, {int limit = kSearchIndexRankLimit}) async => null,
      );
      expect(ids, isNull);
    });

    test('search 返回空列表（真实空结果）→ 不回退，空排行', () async {
      final ids = await resolveRankedSearch(
        'q',
        (q, {int limit = kSearchIndexRankLimit}) async => const [],
      );
      expect(ids, isNotNull);
      expect(ids, isEmpty);
    });

    test('透传 limit', () async {
      int? seen;
      await resolveRankedSearch(
        'q',
        (q, {int limit = kSearchIndexRankLimit}) async {
          seen = limit;
          return const [];
        },
        limit: 42,
      );
      expect(seen, 42);
    });
  });
}
