// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 壳页面级「选择」状态（跨壳内容卸载/重挂载保留）。
///
/// 全屏播放页展开动画结束后，`ShellExpandTransition` 会把整个壳内容
/// （含各页 `State`）从树上卸载以释放列表/图片内存，收起时再重新挂载。
/// 若把「当前平台 NT/KG/QM」这类轻量选择存在页面 `State` 里，重挂载后
/// 会回到默认值——表现就是「每次关掉播放页都跳回 NT」。
///
/// 把它们放进应用级 provider（`ProviderScope` 常驻，不随壳内容销毁）即可
/// 跨卸载保留，且仅在本次运行内有效（不做落盘；如需重启后仍记得，
/// 应另走 `app_prefs`）。
class ShellPageSelection<T> extends Notifier<T?> {
  @override
  T? build() => null;

  /// 记录选择；相同则不动（避免无谓通知）。传 null 表示恢复「未选择」。
  void set(T? value) {
    if (state == value) return;
    state = value;
  }
}

/// 搜索页当前来源平台：'netease' / 'kugou' / 'qqmusic' / 'all'（聚合）。
final searchPlatformProvider =
    NotifierProvider<ShellPageSelection<String>, String?>(
      ShellPageSelection<String>.new,
    );

/// 搜索页当前 Tab（0 歌曲 / 1 专辑 / 2 歌手 / 3 歌单）。
final searchTabIndexProvider = NotifierProvider<ShellPageSelection<int>, int?>(
  ShellPageSelection<int>.new,
);

/// 「我喜欢」页当前来源平台：'netease' / 'kugou' / 'qqmusic' / 'neko'。
final likedPlatformProvider =
    NotifierProvider<ShellPageSelection<String>, String?>(
      ShellPageSelection<String>.new,
    );

/// 「收藏」页当前来源平台：'netease' / 'kugou' / 'qqmusic' / 'neko'。
final favoritesPlatformProvider =
    NotifierProvider<ShellPageSelection<String>, String?>(
      ShellPageSelection<String>.new,
    );

/// 「收藏」页 NT 分类 Tab（`_FavTab.name`：playlist / album / artist）。
final favoritesNeteaseTabProvider =
    NotifierProvider<ShellPageSelection<String>, String?>(
      ShellPageSelection<String>.new,
    );

/// 「收藏」页 KG 分类 Tab（`_KgTab.name`）。
final favoritesKugouTabProvider =
    NotifierProvider<ShellPageSelection<String>, String?>(
      ShellPageSelection<String>.new,
    );

/// 「收藏」页 QM 分类 Tab（`_QqTab.name`）。
final favoritesQqTabProvider =
    NotifierProvider<ShellPageSelection<String>, String?>(
      ShellPageSelection<String>.new,
    );

/// 「收藏」页 Neko 分类 Tab（`_NekoTab.name`）。
final favoritesNekoTabProvider =
    NotifierProvider<ShellPageSelection<String>, String?>(
      ShellPageSelection<String>.new,
    );

/// 流媒体页当前 Tab（0 歌曲 / 1 专辑 / 2 歌手 / 3 歌单）。
final streamingTabIndexProvider =
    NotifierProvider<ShellPageSelection<int>, int?>(
      ShellPageSelection<int>.new,
    );
