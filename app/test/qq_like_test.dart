// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// QM红心（收藏）单元测试（**不联网**）。
///
/// 覆盖：
/// - 红心键路由：songmid 为键（QqLikedStore.qqLikeKey / SongRow.songLikeKey
///   一致），彻底避免「QQ 曲目误走NT数字 id」；
/// - [QqLikedStore] 本机持久化：add/remove/mergeOnline（add-only 不覆盖本地）
///   与跨实例重载（模拟重启）；
/// - [QqMusicApi] 在线收藏参数 / 登录护栏：缺 songId、未登录写读均抛可读
///   [QqApiException]（**不触发网络**，仅验证参数/结构校验与降级语义）；
/// - [LikeController] 离线本地红心：未登录 QQ 时 toggle 走本机库（始终可用）。
///
/// 说明：已登录的在线写接口（favorite_add/favorite_remove/dirid=201）为社区
/// 逆向实验 RPC，需真机扫码登录后验证（见 favorite.dart / kQqFavExperimental）。
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/netease/track.dart';
import 'package:archoera_music/services/qqmusic/qq_liked_store.dart';
import 'package:archoera_music/services/qqmusic/qqmusic_api.dart';
import 'package:archoera_music/stores/providers.dart';
import 'package:archoera_music/widgets/list/song_row.dart';

Track _qqTrack(String id, String mid, {String title = '测试曲'}) => Track(
  id: id,
  title: title,
  artists: const [TrackArtist(name: '测试歌手')],
  source: 'qqmusic',
  qqmusic: QqMusicTrackInfo(mid: mid),
);

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('qq_like_test');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  // ── 红心键路由 ────────────────────────────────────────────────────

  group('QQ 红心键（songmid）', () {
    test('QqLikedStore.qqLikeKey 以 songmid 为键，缺失回退数字 id', () {
      expect(
        qqLikeKey(_qqTrack('1162906679', '004Z8Ihr0JIu5s')),
        '004Z8Ihr0JIu5s',
      );
      final noMid = Track(
        id: '1162906679',
        title: '无 mid',
        source: 'qqmusic',
        qqmusic: const QqMusicTrackInfo(mid: ''),
      );
      expect(qqLikeKey(noMid), '1162906679');
    });

    test('SongRow.songLikeKey 与 LikeController 路由键一致（songmid）', () {
      final t = _qqTrack('1162906679', '004Z8Ihr0JIu5s');
      expect(songLikeKey(t), '004Z8Ihr0JIu5s');
      // NT仍用数字 id（避免被 QQ songmid 串扰）
      final ne = Track(id: '28451655', title: '网易', source: 'netease');
      expect(songLikeKey(ne), '28451655');
    });
  });

  // ── 本机持久化（离线始终可用） ────────────────────────────────────

  group('QqLikedStore 本机红心持久化', () {
    test('add 幂等/remove/mergeOnline add-only + 重载持久化', () async {
      final store = QqLikedStore(dir: tmp.path);
      await store.ensureLoaded();
      final a = _qqTrack('1', 'midA', title: 'A');
      final b = _qqTrack('2', 'midB', title: 'B');
      final c = _qqTrack('3', 'midC', title: 'C');

      await store.add(a);
      await store.add(b);
      expect(store.midSet, {'midA', 'midB'});
      expect(store.tracks.first.qqmusic!.mid, 'midB'); // 最新在前

      // add 幂等
      await store.add(b);
      expect(store.tracks.length, 2);

      // removeByKey（兼容数字 id 兜底）
      await store.removeByKey('midA');
      await store.flush();
      expect(store.midSet, {'midB'});

      // 模拟重启：新实例重载文件
      final reloaded = QqLikedStore(dir: tmp.path);
      await reloaded.ensureLoaded();
      expect(reloaded.midSet, {'midB'});
      expect(reloaded.tracks.single.qqmusic!.mid, 'midB');

      // mergeOnline add-only：并入新歌但绝不覆盖本地（在线缺 B 也不会删）
      final n = await reloaded.mergeOnline([a, c]);
      await reloaded.flush();
      expect(n, 2);
      expect(reloaded.midSet, {'midB', 'midA', 'midC'});

      // 重复并入幂等
      expect(await reloaded.mergeOnline([c]), 0);

      // 再次重载确认
      final reloaded2 = QqLikedStore(dir: tmp.path);
      await reloaded2.ensureLoaded();
      expect(reloaded2.midSet, {'midB', 'midA', 'midC'});
    });
  });

  // ── QqMusicApi 在线收藏护栏（不联网） ─────────────────────────────

  group('QqMusicApi 收藏参数 / 登录护栏（离线）', () {
    final api = QqMusicApi();

    test('like 缺 songId（写接口按 songid 操作）抛可读异常', () async {
      await expectLater(
        api.like('midX', like: true),
        throwsA(
          isA<QqApiException>().having(
            (e) => e.message,
            'message',
            contains('songId'),
          ),
        ),
      );
    });

    test('like songId 非数字抛可读异常', () async {
      await expectLater(
        api.like('midX', like: true, songId: 'abc'),
        throwsA(isA<QqApiException>()),
      );
    });

    test('like 未登录 QQ 时抛「需要登录」（不触发网络）', () async {
      await expectLater(
        api.like('midX', like: true, songId: '1162906679'),
        throwsA(
          isA<QqApiException>().having(
            (e) => e.message,
            'message',
            contains('登录'),
          ),
        ),
      );
    });

    test('likedSongmids / likedSongs 未登录抛「需要登录」', () async {
      await expectLater(
        api.likedSongmids(),
        throwsA(
          isA<QqApiException>().having(
            (e) => e.message,
            'message',
            contains('登录'),
          ),
        ),
      );
      await expectLater(
        api.likedSongs(),
        throwsA(
          isA<QqApiException>().having(
            (e) => e.message,
            'message',
            contains('登录'),
          ),
        ),
      );
    });
  });

  // ── LikeController 离线本地红心（不登录，始终可用） ───────────────

  group('LikeController QQ 本地红心（离线）', () {
    test('未登录 QQ 时 toggle 走本机库：点亮/熄灭 + store 同步', () async {
      final container = ProviderContainer(
        overrides: [
          qqMusicApiProvider.overrideWith((_) => QqMusicApi()),
          qqLikedStoreProvider.overrideWith(
            (_) => QqLikedStore(dir: tmp.path),
          ),
        ],
      );
      addTearDown(container.dispose);
      final qqStore = container.read(qqLikedStoreProvider);
      await qqStore.ensureLoaded();
      final ctrl = container.read(likeControllerProvider);

      final t = _qqTrack('1162906679', '004Z8Ihr0JIu5s');
      expect(ctrl.isLiked(t), isFalse);
      expect(qqStore.containsMid('004Z8Ihr0JIu5s'), isFalse);

      final ok = await ctrl.toggle(t);
      expect(ok, isTrue);
      expect(ctrl.isLiked(t), isTrue);
      expect(qqStore.containsMid('004Z8Ihr0JIu5s'), isTrue);

      final ok2 = await ctrl.toggle(t);
      expect(ok2, isTrue);
      expect(ctrl.isLiked(t), isFalse);
      expect(qqStore.containsMid('004Z8Ihr0JIu5s'), isFalse);
    });
  });
}
