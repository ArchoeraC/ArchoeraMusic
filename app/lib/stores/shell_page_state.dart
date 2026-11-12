// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 壳页面级「选择」状态（跨页面 / 路由保留）。
///
/// 全屏播放页展开时壳内容只停绘、不再卸载（2026-11-09），但把「当前平台
/// NT/KG/QM」这类轻量选择放到应用级 provider（`ProviderScope` 常驻）仍有
/// 价值：页面切换、分支重建、深链返回时都不会回到默认值。仅本次运行内
/// 有效（不做落盘；如需重启后仍记得，应另走 `app_prefs`）。
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

/// 顶栏**全局搜索框**的当前文本（跨页面保留；null = 空）。
///
/// 若文本只存在组件内部的 `TextEditingController`，页面切换 / 顶栏重建时会丢；
/// 而 `/search` 页的查询来自路由 `?q=`（按路由恢复并重新拉取）——于是出现
/// 「结果仍按旧关键词筛选，搜索框却空了」的不一致（与音乐库搜索框同一类问题）。
///
/// 与 [searchPlatformProvider] 同法：把文本上提到应用级 provider，输入时写入、
/// 重建时回填，使其始终与搜索页展示的查询一致（深链 `/search?q=` 也由搜索页
/// 回写，见 `pages/search_page.dart`）。
final navSearchQueryProvider =
    NotifierProvider<ShellPageSelection<String>, String?>(
      ShellPageSelection<String>.new,
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
