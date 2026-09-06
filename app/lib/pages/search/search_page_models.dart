// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../search_page.dart';

/// 单个 Tab 的分页状态（对齐 Search.vue 的 `TabState<T>`）。
class _TabState<T> {
  const _TabState({
    this.items = const [],
    this.total = 0,
    this.hasMore = false,
    this.loaded = false,
    this.loading = false,
    this.loadingMore = false,
  });

  final List<T> items;
  final int total;
  final bool hasMore;
  final bool loaded;
  final bool loading;
  final bool loadingMore;

  _TabState<T> copyWith({
    List<T>? items,
    int? total,
    bool? hasMore,
    bool? loaded,
    bool? loading,
    bool? loadingMore,
  }) {
    return _TabState<T>(
      items: items ?? this.items,
      total: total ?? this.total,
      hasMore: hasMore ?? this.hasMore,
      loaded: loaded ?? this.loaded,
      loading: loading ?? this.loading,
      loadingMore: loadingMore ?? this.loadingMore,
    );
  }
}

enum _SearchTab { songs, albums, artists, playlists }

/// 聚合搜索中单个平台的游标（各平台分页锚点：已加载条数 + 是否还有更多）。
///
/// 还记录该源最近一次失败（[failed]/[error]/[failedAt]），用于「该源暂不可
/// 用」占位 + 手动重试（成功清除）。
class _AggState {
  int loaded = 0;
  bool hasMore = true;
  int total = 0;
  bool failed = false;
  Object? error;
  DateTime? failedAt;
}

/// 参与聚合搜索的平台（netease 用 offset / kugou·qqmusic 用 page 游标）。
const _aggPlatforms = ['netease', 'kugou', 'qqmusic'];
