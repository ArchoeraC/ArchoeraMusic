// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 「收藏 / 我喜欢」平台注册表测试：注册项、分类 Tab、红心键归一、能力位。
///
/// 两个页面与 `LikedStore`/`LikeController` 的行为都由本注册表驱动；这里锁定
/// 各平台声明，避免以后改注册项时悄悄改变页面形态或红心路由。
library;

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/l10n/generated/app_localizations.dart';
import 'package:archoera_music/services/kugou/kugou_api.dart';
import 'package:archoera_music/services/neko/neko_api.dart';
import 'package:archoera_music/services/neko/neko_types.dart';
import 'package:archoera_music/services/netease/apis_netease_caller.dart';
import 'package:archoera_music/services/netease/netease_api.dart';
import 'package:archoera_music/services/netease/track.dart';
import 'package:archoera_music/services/qqmusic/qqmusic_api.dart';
import 'package:archoera_music/stores/providers.dart';
import 'package:archoera_music/widgets/dialogs/collection_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final l10n = lookupAppLocalizations(const Locale('zh'));

  test('已注册平台与未注册回退 NT', () {
    for (final s in const ['netease', 'kugou', 'qqmusic', 'neko']) {
      expect(collectionPlatform(s).source, s, reason: '$s 未注册或错位');
    }
    expect(collectionPlatform('streaming').source, 'netease');
    expect(collectionPlatform('subsonic').source, 'netease');
  });

  test('分类 Tab：tabs() 与 tabIds 一致，且含默认项', () {
    expect(collectionPlatform('netease').tabIds, [
      'playlist',
      'album',
      'artist',
    ]);
    expect(collectionPlatform('kugou').tabIds, [
      'created',
      'collectedPlaylist',
      'collectedAlbum',
    ]);
    expect(collectionPlatform('qqmusic').tabIds, [
      'created',
      'collectedPlaylist',
      'liked',
    ]);
    expect(collectionPlatform('neko').tabIds, [
      'created',
      'collectedPlaylist',
      'liked',
    ]);

    for (final s in const ['netease', 'kugou', 'qqmusic', 'neko']) {
      final p = collectionPlatform(s);
      expect(p.tabs(l10n).map((t) => t.id).toList(), p.tabIds);
      expect(p.tabIds.contains(p.defaultTabId), isTrue);
      expect(p.tabKey(p.defaultTabId), '$s.${p.defaultTabId}');
    }
  });

  test('红心键归一（KG 小写 hash / 其余 id）', () {
    Track t(String source) => Track(id: 'AbC', title: 'x', source: source);
    expect(collectionPlatform('netease').likeKey(t('netease')), 'AbC');
    expect(collectionPlatform('neko').likeKey(t('neko')), 'AbC');
    expect(collectionPlatform('kugou').likeKey(t('kugou')), 'abc');
    expect(collectionPlatform('qqmusic').likeKey(t('qqmusic')), 'AbC');
  });

  test('本机库 / 对账能力位', () {
    expect(collectionPlatform('qqmusic').localLikedStore, isTrue);
    expect(collectionPlatform('qqmusic').reconcileLiked, isFalse);
    for (final s in const ['netease', 'kugou', 'neko']) {
      expect(collectionPlatform(s).localLikedStore, isFalse);
      expect(collectionPlatform(s).reconcileLiked, isTrue);
    }
  });

  // 回归：`ref` 参数是 dynamic，`ref.read(...)` 返回 dynamic；若适配器里不把
  // API 取成有静态类型的局部变量，`.where`/`.map` 会走动态派发——闭包参数退化
  // 为 dynamic，`map(...).toList()` 产出 `List<dynamic>`。收藏页此前用「静默
  // 失败」把运行时类型错误当空列表吞掉，掩盖了缺陷；改为错误态后暴露。
  // 这里用假 Provider 真跑一遍 fetchFavorites，锁定返回值为 List<CoverItem>。
  test('fetchFavorites 返回 List<CoverItem>（防 dynamic 派发回归）', () async {
    final container = ProviderContainer(
      overrides: [
        neteaseApiProvider.overrideWithValue(_FakeNeteaseApi()),
        neteaseAuthProvider.overrideWith(_FakeNeteaseAuth.new),
        kugouApiProvider.overrideWith((ref) => _FakeKugouApi()),
        qqMusicApiProvider.overrideWith((ref) => _FakeQqMusicApi()),
        nekoApiProvider.overrideWith((ref) => _FakeNekoApi()),
      ],
    );
    addTearDown(container.dispose);

    final nt = await collectionPlatform(
      'netease',
    ).fetchFavorites(container, 'playlist');
    expect(nt['netease.playlist'], isA<List<CoverItem>>());
    // 只保留 subscribed 的收藏歌单（id '1'），过滤掉自建的 '2'。
    expect(nt['netease.playlist']!.map((e) => e.id).toList(), ['1']);

    final kg = await collectionPlatform(
      'kugou',
    ).fetchFavorites(container, 'created');
    expect(kg['kugou.created'], isA<List<CoverItem>>());
    expect(kg['kugou.created']!.single.title, 'c1');
    expect(kg['kugou.collectedPlaylist']!.single.title, 'p1');
    expect(kg['kugou.collectedAlbum']!.single.title, 'a1');

    final nk = await collectionPlatform(
      'neko',
    ).fetchFavorites(container, 'created');
    expect(nk['neko.created'], isA<List<CoverItem>>());
    expect(nk['neko.created']!.single.title, 'n1');
    expect(nk['neko.collectedPlaylist']!.single.title, 'n2');
    expect(nk['neko.liked']!.single.title, '我喜欢');

    final qq = await collectionPlatform(
      'qqmusic',
    ).fetchFavorites(container, 'created');
    expect(qq['qqmusic.created'], isA<List<CoverItem>>());
  });
}

// ── 假 API（仅覆盖 fetchFavorites 触及的方法） ──────────────────────

class _FakeNeteaseAuth extends NeteaseAuthNotifier {
  @override
  NeteaseAccount? build() =>
      const NeteaseAccount(userId: 'u1', nickname: 'tester');
}

class _FakeNeteaseApi extends NeteaseApi {
  _FakeNeteaseApi() : super(ApisNeteaseCaller());

  @override
  Future<List<PlaylistItem>> userPlaylists(String uid, {int limit = 200}) async {
    return const [
      PlaylistItem(id: '1', name: 'sub', subscribed: true),
      PlaylistItem(id: '2', name: 'own'),
    ];
  }

  @override
  Future<List<CoverItem>> albumSublist({int limit = 100, int offset = 0}) async {
    return const [];
  }

  @override
  Future<List<CoverItem>> artistSublist({
    int limit = 100,
    int offset = 0,
  }) async {
    return const [];
  }
}

class _FakeKugouApi extends KugouApi {
  @override
  Future<KugouLibrary> userLibrary() async {
    return const KugouLibrary(
      items: [
        KugouLibraryItem(
          type: KugouLibraryType.createdPlaylist,
          id: 'c1',
          title: 'c1',
        ),
        KugouLibraryItem(
          type: KugouLibraryType.collectedPlaylist,
          id: 'p1',
          title: 'p1',
        ),
        KugouLibraryItem(
          type: KugouLibraryType.collectedAlbum,
          id: 'a1',
          title: 'a1',
        ),
      ],
    );
  }
}

class _FakeNekoApi extends NekoApi {
  @override
  Future<NekoUserLibrary> userLibrary() async {
    return const NekoUserLibrary(
      createdPlaylists: [NekoPlaylist(id: 'n1', name: 'n1')],
      collectedPlaylists: [NekoPlaylist(id: 'n2', name: 'n2')],
      isVip: false,
    );
  }

  @override
  Future<Set<String>> likedIds() async => {'n1'};
}

class _FakeQqMusicApi extends QqMusicApi {
  @override
  Future<
    ({
      List<CoverItem> created,
      List<CoverItem> collected,
      int likedTotal,
      String likedCover,
    })
  >
  userLibrary() async => (
    created: const <CoverItem>[],
    collected: const <CoverItem>[],
    likedTotal: 0,
    likedCover: '',
  );
}
