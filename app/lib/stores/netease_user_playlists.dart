// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 网易云「用户歌单」（自建 + 收藏）缓存与写操作。
///
/// 供歌单详情弹窗（收藏 / 编辑 / 删除）、歌单选择器（加入歌曲的目标歌单）
/// 共用：登录后 [`ensureLoaded`] 拉一次 `user_playlist`，写操作成功后刷新，
/// 并 `bump` [favoritesRevisionProvider] 让收藏页联动重拉。
///
/// 判定语义（对齐原项目 userStore）：
/// - `subscribed == true` → 收藏的歌单；
/// - `subscribed == false` → 自建歌单（含首位的「我喜欢的音乐」）。
/// 自建歌单不可「收藏」，只能编辑 / 删除；收藏的歌单可取消收藏。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/netease/track.dart';
import 'favorites_revision.dart';
import 'providers.dart';

/// 用户歌单快照。
class NeteaseUserPlaylists {
  const NeteaseUserPlaylists({
    this.all = const [],
    this.loaded = false,
    this.loading = false,
    this.error,
  });

  /// 全部歌单（user_playlist 原序：自建在前，收藏在后）。
  final List<PlaylistItem> all;

  /// 是否已成功拉取过一次。
  final bool loaded;

  /// 是否正在拉取。
  final bool loading;

  /// 上次拉取失败的错误信息（null = 无错误）。
  final String? error;

  /// 自建歌单（`subscribed == false`）。
  List<PlaylistItem> get created =>
      all.where((p) => !p.subscribed).toList(growable: false);

  /// 收藏的歌单（`subscribed == true`）。
  List<PlaylistItem> get subscribed =>
      all.where((p) => p.subscribed).toList(growable: false);

  /// 「我喜欢的音乐」歌单 id（user_playlist 首位且为自建；与
  /// [NeteasePlaylistApi.likedTrackIds] 的「首个歌单」约定一致）。
  String? get likedPlaylistId =>
      all.isNotEmpty && !all.first.subscribed ? all.first.id : null;

  /// 按 id 查找（未找到返回 null）。
  PlaylistItem? findById(String id) {
    for (final p in all) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// 是否为当前用户自建（不可收藏）。
  bool isOwned(String id) {
    final p = findById(id);
    return p != null && !p.subscribed;
  }

  /// 是否已收藏。
  bool isSubscribed(String id) {
    final p = findById(id);
    return p != null && p.subscribed;
  }
}

/// 用户歌单 notifier：拉取 / 刷新 / 收藏切换。
class NeteaseUserPlaylistsNotifier extends Notifier<NeteaseUserPlaylists> {
  @override
  NeteaseUserPlaylists build() => const NeteaseUserPlaylists();

  String? get _uid => ref.read(neteaseAuthProvider)?.userId;

  /// 首次进入时按需加载（已加载/加载中静默跳过）。
  Future<void> ensureLoaded() async {
    if (state.loaded || state.loading) return;
    await refresh();
  }

  /// 重新拉取用户歌单。
  Future<void> refresh() async {
    final uid = _uid;
    if (uid == null || uid.isEmpty) {
      state = const NeteaseUserPlaylists(loaded: true);
      return;
    }
    state = NeteaseUserPlaylists(
      all: state.all,
      loaded: state.loaded,
      loading: true,
    );
    try {
      final list = await ref.read(neteaseApiProvider).userPlaylists(uid);
      state = NeteaseUserPlaylists(all: list, loaded: true);
    } catch (e) {
      state = NeteaseUserPlaylists(
        all: state.all,
        loaded: state.loaded,
        error: '$e',
      );
    }
  }

  /// 收藏 / 取消收藏歌单；成功后刷新列表并通知收藏页。
  Future<void> subscribe(String id, {required bool subscribe}) async {
    await ref
        .read(neteaseApiProvider)
        .subscribePlaylist(id, subscribe: subscribe);
    await refresh();
    ref.read(favoritesRevisionProvider.notifier).bump();
  }

  /// 新建歌单；成功后刷新并返回新歌单 id。
  Future<String?> create(String name, {int privacy = 0}) async {
    final id = await ref
        .read(neteaseApiProvider)
        .createPlaylist(name, privacy: privacy);
    await refresh();
    ref.read(favoritesRevisionProvider.notifier).bump();
    return id;
  }

  /// 删除歌单；成功后刷新并通知收藏页。
  Future<void> remove(String id) async {
    await ref.read(neteaseApiProvider).deletePlaylist(id);
    await refresh();
    ref.read(favoritesRevisionProvider.notifier).bump();
  }

  /// 重命名 / 更新简介（仅传需要改的字段）；成功后刷新并通知收藏页。
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

  /// 添加歌曲到歌单；返回服务端确认加入数（0 = 已存在；未知为 null）。
  /// 成功后刷新并通知收藏页（列表内容变化）。
  Future<int?> addTracks(String id, List<String> trackIds) async {
    final count = await ref
        .read(neteaseApiProvider)
        .playlistAddTracks(id, trackIds);
    await refresh();
    ref.read(favoritesRevisionProvider.notifier).bump();
    return count;
  }

  /// 从歌单移除歌曲；成功后通知收藏页。
  Future<void> removeTracks(String id, List<String> trackIds) async {
    await ref.read(neteaseApiProvider).playlistRemoveTracks(id, trackIds);
    await refresh();
    ref.read(favoritesRevisionProvider.notifier).bump();
  }

  /// 清空（登出时调用）。
  void clear() => state = const NeteaseUserPlaylists();
}

final neteaseUserPlaylistsProvider =
    NotifierProvider<NeteaseUserPlaylistsNotifier, NeteaseUserPlaylists>(
      NeteaseUserPlaylistsNotifier.new,
    );
