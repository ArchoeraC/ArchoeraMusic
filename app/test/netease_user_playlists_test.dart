// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 用户歌单 store 单测：自建 / 收藏划分、收藏切换、以及写操作成功后
/// `bump` [favoritesRevisionProvider]（收藏页联动刷新）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/netease/apis_netease_caller.dart';
import 'package:archoera_music/services/netease/netease_api.dart';
import 'package:archoera_music/services/netease/track.dart';
import 'package:archoera_music/stores/favorites_revision.dart';
import 'package:archoera_music/stores/netease_user_playlists.dart';
import 'package:archoera_music/stores/providers.dart';

/// 记录写操作、返回固定用户歌单的 NT API 桩（不联网）。
class _FakeApi extends NeteaseApi {
  _FakeApi() : super(ApisNeteaseCaller());

  List<PlaylistItem> playlists = const [];
  final List<String> log = [];
  int addCount = 1;

  @override
  Future<List<PlaylistItem>> userPlaylists(
    String uid, {
    int limit = 200,
  }) async => playlists;

  @override
  Future<void> subscribePlaylist(String id, {required bool subscribe}) async {
    log.add('subscribe:$id:$subscribe');
  }

  @override
  Future<String?> createPlaylist(String name, {int privacy = 0}) async {
    log.add('create:$name:$privacy');
    return 'new1';
  }

  @override
  Future<void> deletePlaylist(String id) async => log.add('delete:$id');

  @override
  Future<void> updatePlaylistName(String id, String name) async =>
      log.add('name:$id:$name');

  @override
  Future<void> updatePlaylistDesc(String id, String desc) async =>
      log.add('desc:$id:$desc');

  @override
  Future<int?> playlistAddTracks(String id, List<String> ids) async {
    log.add('add:$id:${ids.join('+')}');
    return addCount;
  }

  @override
  Future<void> playlistRemoveTracks(String id, List<String> ids) async =>
      log.add('del:$id:${ids.join('+')}');
}

class _FakeAuth extends NeteaseAuthNotifier {
  _FakeAuth(this._account);
  final NeteaseAccount? _account;

  @override
  NeteaseAccount? build() => _account;
}

ProviderContainer _container(_FakeApi fake) {
  final container = ProviderContainer(
    overrides: [
      neteaseAuthProvider.overrideWith(
        () => _FakeAuth(const NeteaseAccount(userId: 'u1', nickname: 'n')),
      ),
      neteaseApiProvider.overrideWithValue(fake),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('自建 / 收藏划分与判定', () async {
    final fake = _FakeApi()
      ..playlists = const [
        PlaylistItem(id: 'liked', name: '我喜欢的音乐'),
        PlaylistItem(id: 'own1', name: '我的歌单'),
        PlaylistItem(id: 'col1', name: '收藏的歌单', subscribed: true),
      ];
    final container = _container(fake);
    await container.read(neteaseUserPlaylistsProvider.notifier).ensureLoaded();
    final s = container.read(neteaseUserPlaylistsProvider);

    expect(s.created.map((p) => p.id).toList(), ['liked', 'own1']);
    expect(s.collected.map((p) => p.id).toList(), ['col1']);
    expect(s.isOwned('own1'), isTrue);
    expect(s.isOwned('col1'), isFalse);
    expect(s.isCollected('col1'), isTrue);
    expect(s.isCollected('liked'), isFalse);
    expect(s.likedPlaylistId, 'liked');
  });

  test('收藏切换：调用 API 并 bump 收藏修订号', () async {
    final fake = _FakeApi()
      ..playlists = const [
        PlaylistItem(id: 'col1', name: '收藏的歌单', subscribed: true),
      ];
    final container = _container(fake);
    final notifier = container.read(neteaseUserPlaylistsProvider.notifier);
    await notifier.ensureLoaded();

    final rev0 = container.read(favoritesRevisionProvider);
    await notifier.setCollected('col1', collected: false);
    expect(fake.log, contains('subscribe:col1:false'));
    expect(container.read(favoritesRevisionProvider), rev0 + 1);
  });

  test('新建 / 删除 / 改名 / 增删歌曲均 bump，且参数透传', () async {
    final fake = _FakeApi()..addCount = 3;
    final container = _container(fake);
    final notifier = container.read(neteaseUserPlaylistsProvider.notifier);
    await notifier.ensureLoaded();

    var rev = container.read(favoritesRevisionProvider);
    expect(await notifier.create('新歌单', privacy: 10), 'new1');
    expect(fake.log.last, 'create:新歌单:10');
    expect(container.read(favoritesRevisionProvider), ++rev);

    await notifier.remove('p1');
    expect(fake.log.last, 'delete:p1');
    expect(container.read(favoritesRevisionProvider), ++rev);

    await notifier.updateMeta('p2', name: '改', description: '简介');
    expect(fake.log, containsAllInOrder(['name:p2:改', 'desc:p2:简介']));
    expect(container.read(favoritesRevisionProvider), ++rev);

    expect(await notifier.addTracks('p3', ['a', 'b']), 3);
    expect(fake.log.last, 'add:p3:a+b');
    expect(container.read(favoritesRevisionProvider), ++rev);

    await notifier.removeTracks('p3', ['a']);
    expect(fake.log.last, 'del:p3:a');
    expect(container.read(favoritesRevisionProvider), ++rev);
  });

  test('未登录：refresh 置空且不报错', () async {
    final fake = _FakeApi()
      ..playlists = const [PlaylistItem(id: 'x', name: 'X')];
    final container = ProviderContainer(
      overrides: [
        neteaseAuthProvider.overrideWith(() => _FakeAuth(null)),
        neteaseApiProvider.overrideWithValue(fake),
      ],
    );
    addTearDown(container.dispose);
    await container.read(neteaseUserPlaylistsProvider.notifier).refresh();
    final s = container.read(neteaseUserPlaylistsProvider);
    expect(s.all, isEmpty);
    expect(s.loaded, isTrue);
  });
}
