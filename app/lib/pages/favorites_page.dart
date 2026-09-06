// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/netease/netease_api.dart';
import '../stores/providers.dart';
import '../../l10n/l10n.dart';
import '../widgets/list/cover_grid.dart';
import '../widgets/dialogs/netease_login_dialog.dart';
import '../widgets/dialogs/kugou_login_button.dart';
import '../widgets/player/s_controls.dart';
import '../widgets/streaming/empty_state.dart';
import '../widgets/dialogs/track_list_dialog.dart';

part 'favorites/favorites_page_actions.dart';
part 'favorites/favorites_page_view.dart';

/// 收藏页（对齐原项目 Favorites.vue）。
///
/// 平台切换（NT / KG）：NT三 tab（歌单 / 专辑 / 歌手）保持原逻辑；
/// KG按 MoeKoeMusic Library.vue 对 `/v7/get_all_list` 的分类拆成
/// 「创建的歌单 / 收藏的歌单 / 收藏的专辑」三 tab。未登录对应平台显示登录引导。
class FavoritesPage extends ConsumerStatefulWidget {
  const FavoritesPage({super.key});

  @override
  ConsumerState<FavoritesPage> createState() => _FavoritesPageState();
}

enum _Platform { netease, kugou }

/// NT收藏 tab。
enum _FavTab { playlist, album, artist }

/// KG曲库 tab（对齐 MoeKoeMusic Library.vue 分类）。
enum _KgTab { created, collectedPlaylist, collectedAlbum }

class _FavoritesPageState extends ConsumerState<FavoritesPage> {
  _Platform _platform = _Platform.netease;
  _FavTab _tab = _FavTab.playlist;
  _KgTab _kgTab = _KgTab.created;

  /// 各 tab 缓存数据（key：'netease.playlist' / 'kugou.created' 等；切换保留，
  /// 登录态变化时清空）。
  final Map<String, List<CoverItem>> _cache = {};
  final Map<String, String> _error = {};
  final Set<String> _loading = {};
  final Set<String> _loaded = {};

  bool get _neteaseLoggedIn => ref.read(neteaseAuthProvider) != null;
  bool get _kugouLoggedIn => ref.read(kugouApiProvider).session != null;

  /// 当前平台是否已登录（内容区据此显示数据或登录引导）。
  bool get _loggedIn =>
      _platform == _Platform.kugou ? _kugouLoggedIn : _neteaseLoggedIn;

  String get _cacheKey =>
      '${_platform.name}.'
      '${_platform == _Platform.kugou ? _kgTab.name : _tab.name}';

  /// KG三个 tab 的 key（一次 `/v7/get_all_list` 拉全部分类）。
  static const _kgKeys = [
    'kugou.created',
    'kugou.collectedPlaylist',
    'kugou.collectedAlbum',
  ];

  @override
  void initState() {
    super.initState();
    if (_loggedIn) _fetch();
  }

  void _clearCacheState() {
    _cache.clear();
    _error.clear();
    _loading.clear();
    _loaded.clear();
  }

  void _setPlatform(_Platform platform) {
    setState(() => _platform = platform);
  }

  void _setFavTab(_FavTab tab) {
    setState(() => _tab = tab);
  }

  void _setKgTab(_KgTab tab) {
    setState(() => _kgTab = tab);
  }

  void _markLoading(String key) {
    setState(() {
      _loading.add(key);
      _error.remove(key);
    });
  }

  void _finishFetchSuccess(String key) {
    setState(() {
      _loading.remove(key);
      _loaded.addAll(_platform == _Platform.kugou ? _kgKeys : [key]);
    });
  }

  void _finishFetchError(String key, Object error) {
    setState(() {
      _error[key] = '$error';
      _loading.remove(key);
      _loaded.add(key);
    });
  }

  @override
  Widget build(BuildContext context) => _buildFavoritesPage(context);
}
