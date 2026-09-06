// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 「我喜欢」页刷新 → 红心集合权威对账（**不联网**）回归测试。
///
/// 背景 bug：跨设备新增收藏后，本设备刷新「我喜欢」列表能看到歌曲，但
/// 红心未点亮——列表行来自服务端权威列表，而红心状态用的本地 liked 集合
/// 只在登录/启动 sync 刷新，页面刷新后不对齐。
///
/// 覆盖：
/// - [LikedStore.refresh]（netese/kugou 权威「我喜欢的」拉取点）成功后，
///   把返回键集**双向对账**回 [LikeController] 集合：服务端新增 → 点亮；
///   服务端移除 → 熄灭；并 notifyListeners 触发 UI 重绘；
/// - 缓冲期防竞争：本端刚 toggle（服务端写尚未生效）时，权威旧快照
///   不把刚点亮的熄灭、不把刚熄灭的复活；toggle 失败回滚后缓冲清除、
///   重新让位给服务端权威；
/// - 纯本地 QQ（QqLikedStore 为主源）红心集合 add-only 并入（mergeOnlineQq）。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/kugou/kugou_api.dart';
import 'package:archoera_music/services/liked/liked_loader.dart';
import 'package:archoera_music/services/netease/apis_netease_caller.dart';
import 'package:archoera_music/services/netease/netease_api.dart';
import 'package:archoera_music/services/netease/track.dart';
import 'package:archoera_music/services/qqmusic/qq_liked_store.dart';
import 'package:archoera_music/services/qqmusic/qqmusic_api.dart';
import 'package:archoera_music/stores/like_controller.dart';
import 'package:archoera_music/stores/providers.dart';

// ── 测试曲目 / 假 API ─────────────────────────────────────────────

Track _ntTrack(String id, {String title = '网易曲'}) => Track(
  id: id,
  title: title,
  artists: const [TrackArtist(name: '歌手')],
  source: 'netease',
);

Track _kgTrack(String hash, {String title = 'KG曲'}) => Track(
  id: hash,
  title: title,
  artists: const [TrackArtist(name: '歌手')],
  source: 'kugou',
  kugou: KugouTrackInfo(hash: hash),
);

Track _qqTrack(String mid, {String title = 'QQ曲'}) => Track(
  id: '900001',
  title: title,
  artists: const [TrackArtist(name: '歌手')],
  source: 'qqmusic',
  qqmusic: QqMusicTrackInfo(mid: mid),
);

/// 可控的 NT API 假实现：like 可由测试门控（模拟服务端写未完成）。
class _FakeNeteaseApi extends NeteaseApi {
  _FakeNeteaseApi() : super(ApisNeteaseCaller());

  List<Track> likedSongsResult = const [];
  Future<void> Function(String id, {required bool like})? onLike;

  @override
  Future<List<String>> likedIds(String uid) async => [
    for (final t in likedSongsResult)
      if (t.source == 'netease') t.id,
  ];

  @override
  Future<List<Track>> likedSongs(String uid) async => likedSongsResult;

  @override
  Future<void> like(String id, {required bool like}) async {
    final f = onLike;
    if (f != null) return f(id, like: like);
  }
}

/// 可控的 KG API 假实现（预置登录会话，list 可切，like 可门控/抛错）。
class _FakeKugouApi extends KugouApi {
  _FakeKugouApi() {
    session = const KugouSession(token: 'tok', userid: 'kg1');
  }

  List<Track> likedList = const [];
  Future<void> Function(Track track, {required bool like})? onLike;

  @override
  Future<List<Track>> likedTracks() async => likedList;

  @override
  Future<Set<String>> likedHashSet() async => {
    for (final t in likedList)
      if (t.source == 'kugou') (t.kugou?.hash ?? t.id).toLowerCase(),
  };

  @override
  Future<void> addToLike(Track track) async {
    final f = onLike;
    if (f != null) return f(track, like: true);
  }

  @override
  Future<void> removeFromLike(Track track) async {
    final f = onLike;
    if (f != null) return f(track, like: false);
  }
}

/// 固定返回已登录账号的 NT auth。
class _AuthedNetease extends NeteaseAuthNotifier {
  @override
  NeteaseAccount? build() => const NeteaseAccount(userId: 'nt1', nickname: 't');
}

void main() {
  // ── LikeController 权威对账语义 ──────────────────────────────────

  group('LikeController.reconcileFromAuthoritative（双向对账）', () {
    late ProviderContainer container;
    late _FakeNeteaseApi api;
    late LikeController ctrl;

    setUp(() {
      api = _FakeNeteaseApi();
      container = ProviderContainer(
        overrides: [neteaseApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      ctrl = container.read(likeControllerProvider);
    });

    test('权威列表含 → 点亮；不含 → 熄灭；变化时通知 UI', () {
      var notified = 0;
      ctrl.addListener(() => notified++);
      final a = _ntTrack('1');
      final b = _ntTrack('2');

      ctrl.reconcileFromAuthoritative('netease', [a, b]);
      expect(ctrl.isLiked(a), isTrue);
      expect(ctrl.isLiked(b), isTrue);
      expect(ctrl.idsFor('netease'), {'1', '2'});
      expect(notified, 1);

      // 跨设备移除 a：刷新后红心熄灭（仅 b 保留）
      ctrl.reconcileFromAuthoritative('netease', [b]);
      expect(ctrl.isLiked(a), isFalse);
      expect(ctrl.isLiked(b), isTrue);
      expect(notified, 2);

      // 无变化不通知
      ctrl.reconcileFromAuthoritative('netease', [b]);
      expect(notified, 2);
    });

    test('混合列表里只取同平台键（非本平台来源行不污染）', () {
      final a = _ntTrack('1');
      final foreign = _kgTrack('ABC');
      ctrl.reconcileFromAuthoritative('netease', [a, foreign]);
      expect(ctrl.idsFor('netease'), {'1'});
    });

    test('缓冲期：本端刚点亮（服务端写未完成）不被权威旧快照熄灭', () async {
      final gate = Completer<void>();
      api.onLike = (id, {required bool like}) => gate.future;
      final a = _ntTrack('1');

      final toggle = ctrl.toggle(a); // 乐观点亮，服务端挂起
      expect(ctrl.isLiked(a), isTrue);

      // 旧快照（尚无 a，如服务端写未生效）刷新 → 不误熄灭
      ctrl.reconcileFromAuthoritative('netease', const <Track>[]);
      expect(ctrl.isLiked(a), isTrue, reason: '缓冲期内本端刚点亮不应被权威旧快照清除');

      gate.complete();
      await toggle;
      expect(ctrl.isLiked(a), isTrue);
    });

    test('缓冲期：本端刚熄灭不被权威旧快照复活', () async {
      final a = _ntTrack('1');
      ctrl.reconcileFromAuthoritative('netease', [a]);
      expect(ctrl.isLiked(a), isTrue);

      final gate = Completer<void>();
      api.onLike = (id, {required bool like}) => gate.future;
      final toggle = ctrl.toggle(a); // 乐观熄灭，服务端挂起
      expect(ctrl.isLiked(a), isFalse);

      // 服务端滞后仍含 a 的旧快照刷新 → 不复活
      ctrl.reconcileFromAuthoritative('netease', [a]);
      expect(ctrl.isLiked(a), isFalse, reason: '缓冲期内本端刚熄灭不应被权威旧快照回光');

      gate.complete();
      await toggle;
      expect(ctrl.isLiked(a), isFalse);
    });

    test('toggle 失败回滚后缓冲清除，重新让位给服务端权威', () async {
      final a = _ntTrack('1');
      final gate = Completer<void>();
      api.onLike = (id, {required bool like}) {
        gate.completeError(Exception('写失败'));
        return gate.future;
      };

      final ok = await ctrl.toggle(a);
      expect(ok, isFalse, reason: '服务端写失败应返回 false');
      expect(ctrl.isLiked(a), isFalse, reason: '失败回滚');

      // 缓冲已清除：权威列表（服务端仍收藏）刷新 → 恢复点亮
      ctrl.reconcileFromAuthoritative('netease', [a]);
      expect(ctrl.isLiked(a), isTrue);
    });

    test('非权威平台（普通歌单来源）不入网：qqmusic 参数被忽略', () {
      final q = _qqTrack('MIDX');
      ctrl.reconcileFromAuthoritative('qqmusic', [q]);
      expect(ctrl.idsFor('qqmusic'), isEmpty);
    });
  });

  // ── LikedStore 刷新 → 红心对账（权威「我喜欢的」拉取点） ─────────

  group('LikedStore.refresh → 权威列表对账红心', () {
    test('KG：刷新新增点亮 / 移除熄灭（跨设备场景）', () async {
      final kg = _FakeKugouApi();
      final container = ProviderContainer(
        overrides: [kugouApiProvider.overrideWith((_) => kg)],
      );
      addTearDown(container.dispose);
      final ctrl = container.read(likeControllerProvider);
      final store = container.read(likedStoreProvider);

      // 另一台设备已收藏 A、B → 本设备刷新（list 大写 hash 也应命中）
      kg.likedList = [_kgTrack('HASH_A'), _kgTrack('HASH_B')];
      await store.refresh('kugou', writeCache: false);
      expect(
        ctrl.isLiked(_kgTrack('HASH_A')),
        isTrue,
        reason: '跨设备新增的 A 在刷新后红心应点亮',
      );
      expect(ctrl.idsFor('kugou'), {'hash_a', 'hash_b'});

      // 另一台设备取消了 A → 本设备再刷新 → A 熄灭、B 保留
      kg.likedList = [_kgTrack('HASH_B')];
      await store.refresh('kugou', writeCache: false);
      expect(
        ctrl.isLiked(_kgTrack('HASH_A')),
        isFalse,
        reason: '跨设备移除的 A 在刷新后红心应熄灭',
      );
      expect(ctrl.isLiked(_kgTrack('HASH_B')), isTrue);
    });

    test('NT：刷新返回服务端权威列表后红心与列表一致', () async {
      final api = _FakeNeteaseApi();
      final container = ProviderContainer(
        overrides: [
          neteaseApiProvider.overrideWithValue(api),
          neteaseAuthProvider.overrideWith(_AuthedNetease.new),
        ],
      );
      addTearDown(container.dispose);
      final ctrl = container.read(likeControllerProvider);
      final store = container.read(likedStoreProvider);

      api.likedSongsResult = [_ntTrack('1'), _ntTrack('2')];
      await store.refresh('netease', writeCache: false);
      expect(ctrl.isLiked(_ntTrack('1')), isTrue);
      expect(ctrl.idsFor('netease'), {'1', '2'});

      api.likedSongsResult = [_ntTrack('2')];
      await store.refresh('netease', writeCache: false);
      expect(ctrl.isLiked(_ntTrack('1')), isFalse);
      expect(ctrl.isLiked(_ntTrack('2')), isTrue);
    });
  });

  // ── QQ：本机红心为主源，在线并入 add-only ───────────────────────

  group('LikeController QQ 在线并入（add-only）', () {
    test('mergeOnlineQq 只并入不熄灭（对应 QqLikedStore.mergeOnline）', () {
      final tmp = Directory.systemTemp.createTempSync('liked_reconcile_qq');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });
      final container = ProviderContainer(
        overrides: [
          qqMusicApiProvider.overrideWith((_) => QqMusicApi()),
          qqLikedStoreProvider.overrideWith((_) => QqLikedStore(dir: tmp.path)),
        ],
      );
      addTearDown(container.dispose);
      final ctrl = container.read(likeControllerProvider);

      ctrl.mergeOnlineQq([_qqTrack('MID_A'), _qqTrack('MID_B')]);
      expect(ctrl.idsFor('qqmusic'), {'MID_A', 'MID_B'});

      // 在线列表变化：已并保留；新来并入；绝不熄灭本机已有
      ctrl.mergeOnlineQq([_qqTrack('MID_B'), _qqTrack('MID_C')]);
      expect(ctrl.idsFor('qqmusic'), {'MID_A', 'MID_B', 'MID_C'});

      // 空并入幂等
      ctrl.mergeOnlineQq(const []);
      expect(ctrl.idsFor('qqmusic'), {'MID_A', 'MID_B', 'MID_C'});
    });
  });
}
