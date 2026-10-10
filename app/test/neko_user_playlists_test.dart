// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Neko 用户歌单 store 单测：自建 / 收藏划分、写操作透传与收藏修订号联动。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/neko/neko_api.dart';
import 'package:archoera_music/services/neko/neko_types.dart';
import 'package:archoera_music/stores/favorites_revision.dart';
import 'package:archoera_music/stores/neko_user_playlists.dart';
import 'package:archoera_music/stores/providers.dart';

class _FakeNekoApi extends NekoApi {
  bool loggedIn = true;
  List<NekoPlaylist> created = const [];
  List<NekoPlaylist> collected = const [];
  final List<String> log = [];
  int addCount = 1;

  @override
  bool get isLoggedIn => loggedIn;

  @override
  String resolveUrl(String pathOrUrl) => pathOrUrl;

  @override
  Future<List<NekoPlaylist>> userPlaylists() async => created;

  @override
  Future<List<NekoPlaylist>> favoritePlaylists() async => collected;

  @override
  Future<NekoPlaylist?> createPlaylist(
    String name, {
    String? description,
  }) async {
    log.add('create:$name:${description ?? ''}');
    return const NekoPlaylist(id: 'new1', name: 'x');
  }

  @override
  Future<void> updatePlaylist(
    String id, {
    String? name,
    String? description,
  }) async => log.add('update:$id:$name:$description');

  @override
  Future<void> deletePlaylist(String id) async => log.add('delete:$id');

  @override
  Future<int?> addMusicToPlaylist(String id, List<String> musicIds) async {
    log.add('add:$id:${musicIds.join('+')}');
    return addCount;
  }

  @override
  Future<void> removeMusicFromPlaylist(
    String id,
    List<String> musicIds,
  ) async => log.add('del:$id:${musicIds.join('+')}');

  @override
  Future<void> favoritePlaylist(String id) async => log.add('favorite:$id');

  @override
  Future<void> unfavoritePlaylist(String id) async => log.add('unfavorite:$id');
}

ProviderContainer _container(_FakeNekoApi fake) {
  final container = ProviderContainer(
    overrides: [nekoApiProvider.overrideWith((ref) => fake)],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('自建 / 收藏划分与判定', () async {
    final fake = _FakeNekoApi()
      ..created = const [NekoPlaylist(id: '1', name: 'own')]
      ..collected = const [NekoPlaylist(id: '2', name: 'fav')];
    final container = _container(fake);
    await container.read(nekoUserPlaylistsProvider.notifier).ensureLoaded();
    final s = container.read(nekoUserPlaylistsProvider);

    expect(s.created.map((p) => p.id).toList(), ['1']);
    expect(s.collected.map((p) => p.id).toList(), ['2']);
    expect(s.isOwned('1'), isTrue);
    expect(s.isCollected('2'), isTrue);
    expect(s.likedPlaylistId, isNull);
  });

  test('写操作透传 + bump 收藏修订号', () async {
    final fake = _FakeNekoApi()..addCount = 3;
    final container = _container(fake);
    final notifier = container.read(nekoUserPlaylistsProvider.notifier);
    await notifier.ensureLoaded();

    var rev = container.read(favoritesRevisionProvider);
    await notifier.setCollected('2', collected: false);
    expect(fake.log.last, 'unfavorite:2');
    expect(container.read(favoritesRevisionProvider), ++rev);

    await notifier.setCollected('3', collected: true);
    expect(fake.log.last, 'favorite:3');
    expect(container.read(favoritesRevisionProvider), ++rev);

    expect(await notifier.create('新', description: '简'), 'new1');
    expect(fake.log.last, 'create:新:简');
    expect(container.read(favoritesRevisionProvider), ++rev);

    await notifier.updateMeta('4', name: '改', description: '述');
    expect(fake.log.last, 'update:4:改:述');
    expect(container.read(favoritesRevisionProvider), ++rev);

    expect(await notifier.addTracks('5', ['7', '8']), 3);
    expect(fake.log.last, 'add:5:7+8');
    expect(container.read(favoritesRevisionProvider), ++rev);

    await notifier.removeTracks('5', ['7']);
    expect(fake.log.last, 'del:5:7');

    await notifier.remove('5');
    expect(fake.log.last, 'delete:5');
  });

  test('未登录：refresh 置空且不报错', () async {
    final fake = _FakeNekoApi()
      ..loggedIn = false
      ..created = const [NekoPlaylist(id: '1', name: 'own')];
    final container = _container(fake);
    await container.read(nekoUserPlaylistsProvider.notifier).refresh();
    final s = container.read(nekoUserPlaylistsProvider);
    expect(s.all, isEmpty);
    expect(s.loaded, isTrue);
  });
}
