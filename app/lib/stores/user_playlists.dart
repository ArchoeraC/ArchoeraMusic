// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 跨音源「用户歌单」统一模型与调度。
///
/// 网易云与 Neko 的自建 / 收藏歌单形态不同（NT 用 `subscribed` 标记，Neko 分
/// `/user/playlists` 与 `/user/favorite-playlists` 两个接口），这里归一为
/// [UserPlaylists] + [UserPlaylist]，并给出按 `source` 分发的读写助手，供歌单
/// 详情弹窗、歌单选择器、收藏页共用——UI 不再出现具体平台分支。
///
/// 写操作成功后各 store 自行刷新并 `bump` [favoritesRevisionProvider]。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'neko_user_playlists.dart';
import 'netease_user_playlists.dart';

/// 支持歌单管理的音源（网易云 / Neko）。
const userPlaylistSources = <String>{'netease', 'neko'};

/// 该音源是否支持用户歌单管理。
bool supportsUserPlaylists(String? source) =>
    source != null && userPlaylistSources.contains(source);

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

/// 用户歌单快照（自建 + 收藏）。
class UserPlaylists {
  const UserPlaylists({
    this.all = const [],
    this.loaded = false,
    this.loading = false,
    this.error,
    this.likedId,
  });

  /// 全部歌单（自建在前，收藏在后）。
  final List<UserPlaylist> all;
  final bool loaded;
  final bool loading;
  final String? error;

  /// 「我喜欢的音乐」歌单 id（仅 NT；Neko 为 null）。
  final String? likedId;

  /// 自建歌单。
  List<UserPlaylist> get created =>
      all.where((p) => !p.collected).toList(growable: false);

  /// 收藏的歌单。
  List<UserPlaylist> get collected =>
      all.where((p) => p.collected).toList(growable: false);

  /// 「我喜欢的音乐」歌单 id（无则为 null）。
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

/// 用户歌单读写契约（NT / Neko 各自实现）。
abstract class UserPlaylistsOps {
  Future<void> ensureLoaded();
  Future<void> refresh();

  /// 收藏 / 取消收藏。
  Future<void> setCollected(String id, {required bool collected});

  /// 新建歌单；返回新歌单 id。
  Future<String?> create(String name, {String? description, int privacy = 0});

  /// 删除歌单。
  Future<void> remove(String id);

  /// 重命名 / 更新简介。
  Future<void> updateMeta(String id, {String? name, String? description});

  /// 添加歌曲；返回服务端确认加入数（未知为 null）。
  Future<int?> addTracks(String id, List<String> trackIds);

  /// 移除歌曲。
  Future<void> removeTracks(String id, List<String> trackIds);
}

/// 读取指定音源的歌单快照（不支持时返回空快照）。
UserPlaylists watchUserPlaylists(WidgetRef ref, String? source) =>
    switch (source) {
      'neko' => ref.watch(nekoUserPlaylistsProvider),
      'netease' => ref.watch(neteaseUserPlaylistsProvider),
      _ => const UserPlaylists(loaded: true),
    };

/// 非监听读取（回调用）。
UserPlaylists readUserPlaylists(WidgetRef ref, String? source) =>
    switch (source) {
      'neko' => ref.read(nekoUserPlaylistsProvider),
      'netease' => ref.read(neteaseUserPlaylistsProvider),
      _ => const UserPlaylists(loaded: true),
    };

/// 取指定音源的歌单读写控制器（不支持时为 null）。
UserPlaylistsOps? userPlaylistsOps(WidgetRef ref, String? source) =>
    switch (source) {
      'neko' => ref.read(nekoUserPlaylistsProvider.notifier),
      'netease' => ref.read(neteaseUserPlaylistsProvider.notifier),
      _ => null,
    };
