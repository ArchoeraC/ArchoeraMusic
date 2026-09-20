// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/netease/netease_api.dart';
import '../stores/app_prefs.dart';
import '../stores/providers.dart';
import '../stores/shell_page_state.dart';
import '../../l10n/l10n.dart';
import '../widgets/list/cover_grid.dart';
import '../widgets/dialogs/neko_login_dialog.dart';
import '../widgets/dialogs/netease_login_dialog.dart';
import '../widgets/dialogs/kugou_login_button.dart';
import '../widgets/dialogs/qqmusic_login_dialog.dart';
import '../widgets/player/s_controls.dart';
import '../widgets/streaming/empty_state.dart';
import '../widgets/dialogs/track_list_dialog.dart';
import 'package:archoera_music/eta/icon/eta_icons.dart';

part 'favorites/favorites_page_actions.dart';
part 'favorites/favorites_page_view.dart';

/// 收藏页（对齐原项目 Favorites.vue）。
///
/// 平台切换（NT / KG / QM）：NT三 tab（歌单 / 专辑 / 歌手）保持原逻辑；
/// KG按 MoeKoeMusic Library.vue 对 `/v7/get_all_list` 的分类拆成
/// 「创建的歌单 / 收藏的歌单 / 收藏的专辑」三 tab；QM拆成
/// 「创建的歌单 / 收藏的歌单 / 我喜欢」。未登录对应平台显示登录引导。
class FavoritesPage extends ConsumerStatefulWidget {
  const FavoritesPage({super.key});

  @override
  ConsumerState<FavoritesPage> createState() => _FavoritesPageState();
}

enum _Platform { netease, kugou, qqmusic, neko }

/// NT收藏 tab。
enum _FavTab { playlist, album, artist }

/// KG曲库 tab（对齐 MoeKoeMusic Library.vue 分类）。
enum _KgTab { created, collectedPlaylist, collectedAlbum }

/// QM收藏 tab（自建歌单 / 收藏歌单 / 我喜欢）。
enum _QqTab { created, collectedPlaylist, liked }

/// Neko收藏 tab（自建歌单 / 收藏歌单 / 我喜欢）。
enum _NekoTab { created, collectedPlaylist, liked }

class _FavoritesPageState extends ConsumerState<FavoritesPage> {
  /// 当前平台 / 分类 Tab；均存于 [shell_page_state] provider（跨壳内容
  /// 卸载/重挂载保留），`State` 重建时于 [initState] 恢复。
  late _Platform _platform;
  late _FavTab _tab;
  late _KgTab _kgTab;
  late _QqTab _qqTab;
  late _NekoTab _nekoTab;

  /// 各 tab 缓存数据（key：'netease.playlist' / 'kugou.created' 等；切换保留，
  /// 登录态变化时清空）。
  final Map<String, List<CoverItem>> _cache = {};
  final Map<String, String> _error = {};
  final Set<String> _loading = {};
  final Set<String> _loaded = {};

  bool get _neteaseLoggedIn => ref.read(neteaseAuthProvider) != null;
  bool get _kugouLoggedIn => ref.read(kugouApiProvider).session != null;
  bool get _qqLoggedIn => ref.read(qqMusicApiProvider).isLoggedIn;
  bool get _nekoLoggedIn => ref.read(nekoApiProvider).isLoggedIn;

  /// 当前平台是否已登录（内容区据此显示数据或登录引导）。
  bool get _loggedIn => switch (_platform) {
    _Platform.kugou => _kugouLoggedIn,
    _Platform.qqmusic => _qqLoggedIn,
    _Platform.neko => _nekoLoggedIn,
    _Platform.netease => _neteaseLoggedIn,
  };

  String get _cacheKey {
    final tab = switch (_platform) {
      _Platform.kugou => _kgTab.name,
      _Platform.qqmusic => _qqTab.name,
      _Platform.neko => _nekoTab.name,
      _Platform.netease => _tab.name,
    };
    return '${_platform.name}.$tab';
  }

  /// KG三个 tab 的 key（一次 `/v7/get_all_list` 拉全部分类）。
  static const _kgKeys = [
    'kugou.created',
    'kugou.collectedPlaylist',
    'kugou.collectedAlbum',
  ];

  /// QM三个 tab 的 key（一次 `userLibrary()` 拉全部分类）。
  static const _qqKeys = [
    'qqmusic.created',
    'qqmusic.collectedPlaylist',
    'qqmusic.liked',
  ];

  /// Neko三个 tab 的 key（一次 `userLibrary()` 拉全部分类）。
  static const _nekoKeys = [
    'neko.created',
    'neko.collectedPlaylist',
    'neko.liked',
  ];

  @override
  void initState() {
    super.initState();
    // 恢复上次平台 / 分类选择（壳内容因播放页展开被卸载后重建）。
    var platform = _platformFromName(ref.read(favoritesPlatformProvider));
    // 实验性音源已关闭时不保留 NK 选择（避免对其发请求）。
    if (platform == _Platform.neko &&
        !ref.read(appPrefsProvider).nekoEnabled) {
      platform = _Platform.netease;
    }
    _platform = platform;
    _tab = _favTabFromName(ref.read(favoritesNeteaseTabProvider));
    _kgTab = _kgTabFromName(ref.read(favoritesKugouTabProvider));
    _qqTab = _qqTabFromName(ref.read(favoritesQqTabProvider));
    _nekoTab = _nekoTabFromName(ref.read(favoritesNekoTabProvider));
    if (_loggedIn) _fetch();
  }

  /// provider 里的平台名 → 枚举；无/非法值回退 NT。
  static _Platform _platformFromName(String? name) => switch (name) {
    'kugou' => _Platform.kugou,
    'qqmusic' => _Platform.qqmusic,
    'neko' => _Platform.neko,
    _ => _Platform.netease,
  };

  /// provider 里的分类名 → 枚举；无/非法值回退各自首项。
  static _FavTab _favTabFromName(String? name) => switch (name) {
    'album' => _FavTab.album,
    'artist' => _FavTab.artist,
    _ => _FavTab.playlist,
  };

  static _KgTab _kgTabFromName(String? name) => switch (name) {
    'collectedPlaylist' => _KgTab.collectedPlaylist,
    'collectedAlbum' => _KgTab.collectedAlbum,
    _ => _KgTab.created,
  };

  static _QqTab _qqTabFromName(String? name) => switch (name) {
    'collectedPlaylist' => _QqTab.collectedPlaylist,
    'liked' => _QqTab.liked,
    _ => _QqTab.created,
  };

  static _NekoTab _nekoTabFromName(String? name) => switch (name) {
    'collectedPlaylist' => _NekoTab.collectedPlaylist,
    'liked' => _NekoTab.liked,
    _ => _NekoTab.created,
  };

  void _clearCacheState() {
    _cache.clear();
    _error.clear();
    _loading.clear();
    _loaded.clear();
  }

  void _setPlatform(_Platform platform) {
    ref.read(favoritesPlatformProvider.notifier).set(platform.name);
    setState(() => _platform = platform);
  }

  void _setFavTab(_FavTab tab) {
    ref.read(favoritesNeteaseTabProvider.notifier).set(tab.name);
    setState(() => _tab = tab);
  }

  void _setKgTab(_KgTab tab) {
    ref.read(favoritesKugouTabProvider.notifier).set(tab.name);
    setState(() => _kgTab = tab);
  }

  void _setQqTab(_QqTab tab) {
    ref.read(favoritesQqTabProvider.notifier).set(tab.name);
    setState(() => _qqTab = tab);
  }

  void _setNekoTab(_NekoTab tab) {
    ref.read(favoritesNekoTabProvider.notifier).set(tab.name);
    setState(() => _nekoTab = tab);
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
      _loaded.addAll(switch (_platform) {
        _Platform.kugou => _kgKeys,
        _Platform.qqmusic => _qqKeys,
        _Platform.neko => _nekoKeys,
        _Platform.netease => [key],
      });
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
