// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 用户歌单数据源（[userPlaylistsProvider]）单测：经 `CollectionPlatform`
/// 注册表适配器读写，验证分档缓存、能力位与收藏修订号联动。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/netease/apis_netease_caller.dart';
import 'package:archoera_music/services/netease/netease_api.dart';
import 'package:archoera_music/services/netease/track.dart';
import 'package:archoera_music/stores/favorites_revision.dart';
import 'package:archoera_music/stores/providers.dart';
import 'package:archoera_music/stores/user_playlists.dart';

class _FakeNeteaseApi extends NeteaseApi {
  _FakeNeteaseApi() : super(ApisNeteaseCaller());

  List<PlaylistItem> playlists = const [];
  final List<String> log = [];
  int addCount = 1;

  @override
  Future<List<PlaylistItem>> userPlaylists(
    String uid, {
    int limit = 200,
  }) async => playlists;

  @override
  Future<void> subscribePlaylist(String id, {required bool subscribe}) async =>
      log.add('subscribe:$id:$subscribe');

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

class _FakeNeteaseAuth extends NeteaseAuthNotifier {
  @override
  NeteaseAccount? build() =>
      const NeteaseAccount(userId: 'u1', nickname: 'tester');
}

void main() {
  test('NT：分档判定 + 能力位 + 写操作联动', () async {
    final api = _FakeNeteaseApi()
      ..playlists = const [
        PlaylistItem(id: 'liked', name: '我喜欢的音乐'),
        PlaylistItem(id: 'own1', name: '我的歌单'),
        PlaylistItem(id: 'col1', name: '收藏的歌单', subscribed: true),
      ];
    final container = ProviderContainer(
      overrides: [
        neteaseAuthProvider.overrideWith(_FakeNeteaseAuth.new),
        neteaseApiProvider.overrideWithValue(api),
      ],
    );
    addTearDown(container.dispose);

    final store = container.read(userPlaylistsProvider);
    expect(store.supported('netease'), isTrue);
    await store.ensureLoaded('netease');
    final v = store.view('netease');
    expect(v.created.map((p) => p.id).toList(), ['liked', 'own1']);
    expect(v.collected.map((p) => p.id).toList(), ['col1']);
    expect(v.isOwned('own1'), isTrue);
    expect(v.isCollected('col1'), isTrue);
    expect(v.likedPlaylistId, 'liked');

    final rev0 = container.read(favoritesRevisionProvider);
    await store.setCollected('netease', 'col1', collected: false);
    expect(api.log.last, 'subscribe:col1:false');
    expect(container.read(favoritesRevisionProvider), rev0 + 1);

    expect(await store.addTracks('netease', 'own1', ['a', 'b']), 1);
    expect(api.log.last, 'add:own1:a+b');
  });

  test('不支持音源的适配器：能力位 false、数据为空', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final store = container.read(userPlaylistsProvider);
    expect(store.supported('kugou'), isFalse);
    await store.ensureLoaded('kugou');
    expect(store.view('kugou').all, isEmpty);
    expect(store.view('kugou').loaded, isTrue);
  });
}
