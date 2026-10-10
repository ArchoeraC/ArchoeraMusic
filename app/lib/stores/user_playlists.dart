// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 跨音源「用户歌单」统一模型 + 全局数据源（ChangeNotifier，Riverpod 持有）。
///
/// 仿 [LikedStore]：状态按 `source` 分档缓存，**平台差异全部由
/// [CollectionPlatform] 适配器提供**（见 `widgets/dialogs/collection_platform.dart`
/// 的 `fetchUserPlaylists` / `createPlaylist` 等）。本文件不含任何 `source` 分支，
/// 新增音源只需实现适配器方法，UI 与数据面无需改动。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart' show ChangeNotifierProvider;

import '../widgets/dialogs/collection_platform.dart';
import 'favorites_revision.dart';

/// 归一化后的用户歌单条目。
class UserPlaylist {
  const UserPlaylist({
    required this.id,
    required this.name,
    this.cover,
    this.trackCount = 0,
    this.owner,
    this.description,
    this.collected = false,
  });

  final String id;
  final String name;
  final String? cover;
  final int trackCount;
  final String? owner;
  final String? description;

  /// 是否为「收藏」的歌单（false = 自建 / 我喜欢）。
  final bool collected;
}

/// 某音源的用户歌单快照（自建 + 收藏）。
class UserPlaylists {
  const UserPlaylists({
    this.all = const [],
    this.loaded = false,
    this.loading = false,
    this.error,
    this.likedId,
  });

  final List<UserPlaylist> all;
  final bool loaded;
  final bool loading;
  final String? error;

  /// 「我喜欢的音乐」歌单 id（仅 NT；其余为 null）。
  final String? likedId;

  /// 自建歌单。
  List<UserPlaylist> get created =>
      all.where((p) => !p.collected).toList(growable: false);

  /// 收藏的歌单。
  List<UserPlaylist> get collected =>
      all.where((p) => p.collected).toList(growable: false);

  String? get likedPlaylistId => likedId;

  UserPlaylist? findById(String id) {
    for (final p in all) {
      if (p.id == id) return p;
    }
    return null;
  }

  bool isOwned(String id) {
    final p = findById(id);
    return p != null && !p.collected;
  }

  bool isCollected(String id) {
    final p = findById(id);
    return p != null && p.collected;
  }
}

/// 可变的分档内部状态。
class _SourceState {
  List<UserPlaylist> all = const [];
  String? likedId;
  bool loaded = false;
  bool loading = false;
  String? error;
}

/// 全局「用户歌单」数据源（按 source 分档）。
class UserPlaylistsStore extends ChangeNotifier {
  UserPlaylistsStore(this._ref);

  final Ref _ref;
  final Map<String, _SourceState> _sources = {};

  _SourceState _state(String source) =>
      _sources.putIfAbsent(source, _SourceState.new);

  /// 某音源的歌单快照（只读视图）。
  UserPlaylists view(String source) {
    final s = _state(source);
    return UserPlaylists(
      all: s.all,
      loaded: s.loaded,
      loading: s.loading,
      error: s.error,
      likedId: s.likedId,
    );
  }

  /// 该音源是否支持歌单管理（由适配器声明）。
  bool supported(String source) =>
      collectionPlatform(source).playlistManageSupported(_ref);

  /// 首次进入按需加载（已加载 / 加载中跳过）。
  Future<void> ensureLoaded(String source) async {
    final s = _state(source);
    if (s.loaded || s.loading) return;
    await refresh(source);
  }

  /// 重新拉取。
  Future<void> refresh(String source) async {
    final s = _state(source);
    if (s.loading) return;
    s.loading = true;
    s.error = null;
    notifyListeners();
    try {
      final res = await collectionPlatform(source).fetchUserPlaylists(_ref);
      s.all = res.all;
      s.likedId = res.likedId;
      s.loaded = true;
    } catch (e) {
      s.error = '$e';
    } finally {
      s.loading = false;
      notifyListeners();
    }
  }

  /// 写操作统一收尾：刷新本档 + 通知收藏页。
  Future<void> _afterWrite(String source, Future<void> Function() op) async {
    await op();
    await refresh(source);
    _ref.read(favoritesRevisionProvider.notifier).bump();
  }

  /// 收藏 / 取消收藏。
  Future<void> setCollected(
    String source,
    String id, {
    required bool collected,
  }) => _afterWrite(
    source,
    () =>
        collectionPlatform(source)
            .setPlaylistCollected(_ref, id, collected: collected),
  );

  /// 新建歌单；返回新歌单 id。
  Future<String?> create(
    String source,
    String name, {
    String? description,
    int privacy = 0,
  }) async {
    final id = await collectionPlatform(source)
        .createPlaylist(_ref, name, description: description, privacy: privacy);
    await refresh(source);
    _ref.read(favoritesRevisionProvider.notifier).bump();
    return id;
  }

  /// 删除歌单。
  Future<void> remove(String source, String id) => _afterWrite(
    source,
    () => collectionPlatform(source).deletePlaylist(_ref, id),
  );

  /// 重命名 / 更新简介。
  Future<void> updateMeta(
    String source,
    String id, {
    String? name,
    String? description,
  }) => _afterWrite(
    source,
    () =>
        collectionPlatform(source)
            .updatePlaylist(_ref, id, name: name, description: description),
  );

  /// 添加歌曲；返回服务端确认加入数（未知为 null）。
  Future<int?> addTracks(
    String source,
    String id,
    List<String> trackIds,
  ) async {
    final count = await collectionPlatform(source)
        .addTracksToPlaylist(_ref, id, trackIds);
    await refresh(source);
    _ref.read(favoritesRevisionProvider.notifier).bump();
    return count;
  }

  /// 移除歌曲。
  Future<void> removeTracks(String source, String id, List<String> trackIds) =>
      _afterWrite(
        source,
        () =>
            collectionPlatform(source)
                .removeTracksFromPlaylist(_ref, id, trackIds),
      );
}

final userPlaylistsProvider = ChangeNotifierProvider<UserPlaylistsStore>(
  (ref) => UserPlaylistsStore(ref),
);
