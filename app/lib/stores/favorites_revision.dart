// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 收藏数据变更信号（收藏页据此清缓存并重拉）。
///
/// 歌单收藏 / 取消收藏、新建 / 删除 / 改名、增删曲目等写操作成功后 `bump()`，
/// 收藏页监听本 provider 清空自身 tab 缓存并重新拉取，避免「收藏页还显示旧
/// 列表」。与具体平台无关：任何音源的收藏写操作都可复用。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 收藏数据修订号（自增）。收藏写操作成功后调用 [FavoritesRevision.bump]。
class FavoritesRevision extends Notifier<int> {
  @override
  int build() => 0;

  /// 通知收藏页数据已变更（清缓存 + 重拉）。
  void bump() => state = state + 1;
}

final favoritesRevisionProvider = NotifierProvider<FavoritesRevision, int>(
  FavoritesRevision.new,
);
