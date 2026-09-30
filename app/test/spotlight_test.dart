// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 首页「随机聚光」算法测试：可复现性、来源可用性、起始曲记忆。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/netease/track.dart';
import 'package:archoera_music/services/spotlight/spotlight.dart';

Track _t(String id, [String source = 'netease']) =>
    Track(id: id, title: 'T$id', source: source, artists: const []);

void main() {
  group('SpotlightRng / spotlightSeed', () {
    test('相同种子序列一致（可复现）', () {
      final a = SpotlightRng(12345);
      final b = SpotlightRng(12345);
      for (var i = 0; i < 20; i++) {
        expect(a.nextInt(1000), b.nextInt(1000));
      }
    });

    test('不同重掷次数得到不同种子；nextInt 落在区间内', () {
      final s0 = spotlightSeed('2026-09-30', 0);
      final s1 = spotlightSeed('2026-09-30', 1);
      expect(s0, isNot(equals(s1)));
      final rng = SpotlightRng(s0);
      for (var i = 0; i < 50; i++) {
        final v = rng.nextInt(7);
        expect(v, inInclusiveRange(0, 6));
      }
    });
  });

  group('rollSpotlight', () {
    test('空池返回 null；只从非空来源抽取', () {
      expect(
        rollSpotlight(pools: const {}, rng: SpotlightRng(1)),
        isNull,
      );
      final pick = rollSpotlight(
        pools: {
          SpotlightSource.daily: const [],
          SpotlightSource.local: [_t('a', 'local'), _t('b', 'local')],
        },
        rng: SpotlightRng(1),
      )!;
      expect(pick.source, SpotlightSource.local);
      expect(pick.leadIndex, inInclusiveRange(0, 1));
    });

    test('同种子同池结果一致；起始曲在范围内', () {
      final pools = {
        SpotlightSource.daily: [_t('1'), _t('2'), _t('3')],
        SpotlightSource.liked: [_t('4'), _t('5')],
      };
      final p1 = rollSpotlight(pools: pools, rng: SpotlightRng(99))!;
      final p2 = rollSpotlight(pools: pools, rng: SpotlightRng(99))!;
      expect(p1.source, p2.source);
      expect(p1.leadIndex, p2.leadIndex);
      expect(p1.tracks, isNotEmpty);
      expect(p1.lead, isNotNull);
    });

    test('preview 从起始曲回绕、不超过池子与请求数', () {
      final tracks = [_t('a'), _t('b'), _t('c'), _t('d')];
      final pick = SpotlightPick(
        source: SpotlightSource.local,
        tracks: tracks,
        leadIndex: 2,
      );
      final pv = pick.preview(3);
      expect(pv.map((t) => t.id).toList(), ['c', 'd', 'a']);
      expect(pick.preview(10).length, 4);
      expect(pick.preview(0), isEmpty);
    });
  });

  group('pushRecentLead', () {
    test('最新在前、去重、截断到记忆长度', () {
      var recent = <String>[];
      for (var i = 0; i < 6; i++) {
        recent = pushRecentLead(recent, _t('$i'));
      }
      expect(recent.length, kSpotlightLeadMemory);
      expect(recent.first, 'netease:5');
      expect(recent.toSet().length, recent.length);
      // 重推已存在的 key 会置顶且不重复。
      recent = pushRecentLead(recent, _t('3'));
      expect(recent.first, 'netease:3');
      expect(recent.where((k) => k == 'netease:3').length, 1);
    });
  });
}
