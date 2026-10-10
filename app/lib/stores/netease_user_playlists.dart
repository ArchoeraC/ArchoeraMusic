// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 网易云「用户歌单」（自建 + 收藏）缓存与写操作。
///
/// 归一为 [UserPlaylists]（`subscribed == true` → 收藏；否则自建）。写操作成功
/// 后刷新并 `bump` [favoritesRevisionProvider] 让收藏页联动重拉。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'favorites_revision.dart';
import 'providers.dart';
import 'user_playlists.dart';

/// 用户歌单 notifier：拉取 / 刷新 / 收藏切换。
class NeteaseUserPlaylistsNotifier extends Notifier<UserPlaylists>
    implements UserPlaylistsOps {
  @override
  UserPlaylists build() => const UserPlaylists();

  String? get _uid => ref.read(neteaseAuthProvider)?.userId;

  @override
  Future<void> ensureLoaded() async {
    if (state.loaded || state.loading) return;
    await refresh();
  }

  @override
  Future<void> refresh() async {
    final uid = _uid;
    if (uid == null || uid.isEmpty) {
      state = const UserPlaylists(loaded: true);
      return;
    }
    state = UserPlaylists(
      all: state.all,
      loaded: state.loaded,
      loading: true,
      likedId: state.likedId,
    );
    try {
      final list = await ref.read(neteaseApiProvider).userPlaylists(uid);
      final items = [
        for (final p in list)
          UserPlaylist(
            id: p.id,
            name: p.name,
            cover: p.cover,
            trackCount: p.trackCount,
            owner: p.owner,
            description: p.description,
            collected: p.subscribed,
          ),
      ];
      // 「我喜欢的音乐」= 首位且自建（与 likedTrackIds 的「首个歌单」约定一致）。
      final likedId = items.isNotEmpty && !items.first.collected
          ? items.first.id
          : null;
      state = UserPlaylists(all: items, loaded: true, likedId: likedId);
    } catch (e) {
      state = UserPlaylists(
        all: state.all,
        loaded: state.loaded,
        error: '$e',
        likedId: state.likedId,
      );
    }
  }

  @override
  Future<void> setCollected(String id, {required bool collected}) async {
    await ref
        .read(neteaseApiProvider)
        .subscribePlaylist(id, subscribe: collected);
    await refresh();
    ref.read(favoritesRevisionProvider.notifier).bump();
  }

  @override
  Future<String?> create(
    String name, {
    String? description,
    int privacy = 0,
  }) async {
    final id = await ref
        .read(neteaseApiProvider)
        .createPlaylist(name, privacy: privacy);
    await refresh();
    ref.read(favoritesRevisionProvider.notifier).bump();
    return id;
  }

  @override
  Future<void> remove(String id) async {
    await ref.read(neteaseApiProvider).deletePlaylist(id);
    await refresh();
    ref.read(favoritesRevisionProvider.notifier).bump();
  }

  @override
  Future<void> updateMeta(
    String id, {
    String? name,
    String? description,
  }) async {
    final api = ref.read(neteaseApiProvider);
    if (name != null) await api.updatePlaylistName(id, name);
    if (description != null) await api.updatePlaylistDesc(id, description);
    await refresh();
    ref.read(favoritesRevisionProvider.notifier).bump();
  }

  @override
  Future<int?> addTracks(String id, List<String> trackIds) async {
    final count = await ref
        .read(neteaseApiProvider)
        .playlistAddTracks(id, trackIds);
    await refresh();
    ref.read(favoritesRevisionProvider.notifier).bump();
    return count;
  }

  @override
  Future<void> removeTracks(String id, List<String> trackIds) async {
    await ref.read(neteaseApiProvider).playlistRemoveTracks(id, trackIds);
    await refresh();
    ref.read(favoritesRevisionProvider.notifier).bump();
  }

  /// 清空（登出时调用）。
  void clear() => state = const UserPlaylists();
}

final neteaseUserPlaylistsProvider =
    NotifierProvider<NeteaseUserPlaylistsNotifier, UserPlaylists>(
      NeteaseUserPlaylistsNotifier.new,
    );
