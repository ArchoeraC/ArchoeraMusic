// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// NekoMusic「用户歌单」（自建 + 收藏）缓存与写操作。
///
/// Neko 分两个接口：`/api/user/playlists`（自建）与
/// `/api/user/favorite-playlists`（收藏）；这里归一为 [UserPlaylists]。写操作
/// 成功后刷新并 `bump` [favoritesRevisionProvider]。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/neko/neko_api.dart';
import '../services/neko/neko_types.dart';
import 'favorites_revision.dart';
import 'providers.dart';
import 'user_playlists.dart';

class NekoUserPlaylistsNotifier extends Notifier<UserPlaylists>
    implements UserPlaylistsOps {
  @override
  UserPlaylists build() {
    // 登出：清空缓存，避免残留上一个账号的歌单。
    ref.listen(nekoApiProvider, (prev, next) {
      if ((prev?.isLoggedIn ?? false) && !next.isLoggedIn) {
        state = const UserPlaylists();
      }
    });
    return const UserPlaylists();
  }

  NekoApi get _api => ref.read(nekoApiProvider);

  @override
  Future<void> ensureLoaded() async {
    if (state.loaded || state.loading) return;
    await refresh();
  }

  @override
  Future<void> refresh() async {
    if (!_api.isLoggedIn) {
      state = const UserPlaylists(loaded: true);
      return;
    }
    state = UserPlaylists(all: state.all, loaded: state.loaded, loading: true);
    try {
      final api = _api;
      final created = await api.userPlaylists();
      // 收藏歌单失败不影响自建展示。
      var collected = const <NekoPlaylist>[];
      try {
        collected = await api.favoritePlaylists();
      } catch (_) {
        // 忽略：仅收藏为空
      }
      state = UserPlaylists(
        all: [
          for (final p in created) _toUserPlaylist(p, collected: false),
          for (final p in collected) _toUserPlaylist(p, collected: true),
        ],
        loaded: true,
      );
    } catch (e) {
      state = UserPlaylists(all: state.all, loaded: state.loaded, error: '$e');
    }
  }

  UserPlaylist _toUserPlaylist(NekoPlaylist p, {required bool collected}) =>
      UserPlaylist(
        id: p.id,
        name: p.name,
        cover: _cover(p.firstMusicCover),
        trackCount: p.musicCount,
        owner: p.creator,
        description: p.description,
        collected: collected,
      );

  String? _cover(String? path) {
    if (path == null || path.isEmpty || path.contains('/avatar/default')) {
      return null;
    }
    return _api.resolveUrl(path);
  }

  @override
  Future<void> setCollected(String id, {required bool collected}) async {
    final api = _api;
    if (collected) {
      await api.favoritePlaylist(id);
    } else {
      await api.unfavoritePlaylist(id);
    }
    await refresh();
    ref.read(favoritesRevisionProvider.notifier).bump();
  }

  @override
  Future<String?> create(
    String name, {
    String? description,
    int privacy = 0,
  }) async {
    final created = await _api.createPlaylist(name, description: description);
    await refresh();
    ref.read(favoritesRevisionProvider.notifier).bump();
    return created?.id;
  }

  @override
  Future<void> remove(String id) async {
    await _api.deletePlaylist(id);
    await refresh();
    ref.read(favoritesRevisionProvider.notifier).bump();
  }

  @override
  Future<void> updateMeta(
    String id, {
    String? name,
    String? description,
  }) async {
    await _api.updatePlaylist(id, name: name, description: description);
    await refresh();
    ref.read(favoritesRevisionProvider.notifier).bump();
  }

  @override
  Future<int?> addTracks(String id, List<String> trackIds) async {
    final count = await _api.addMusicToPlaylist(id, trackIds);
    await refresh();
    ref.read(favoritesRevisionProvider.notifier).bump();
    return count;
  }

  @override
  Future<void> removeTracks(String id, List<String> trackIds) async {
    await _api.removeMusicFromPlaylist(id, trackIds);
    await refresh();
    ref.read(favoritesRevisionProvider.notifier).bump();
  }
}

final nekoUserPlaylistsProvider =
    NotifierProvider<NekoUserPlaylistsNotifier, UserPlaylists>(
      NekoUserPlaylistsNotifier.new,
    );
