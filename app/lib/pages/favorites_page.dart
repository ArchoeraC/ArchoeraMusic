// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/netease/netease_api.dart' show CoverItem;
import '../stores/app_prefs.dart';
import '../stores/shell_page_state.dart';
import '../../l10n/l10n.dart';
import '../widgets/list/cover_grid.dart';
import '../widgets/dialogs/collection_platform.dart';
import '../widgets/player/s_controls.dart';
import '../widgets/streaming/empty_state.dart';
import 'package:archoera_music/eta/icon/eta_icons.dart';

part 'favorites/favorites_page_actions.dart';
part 'favorites/favorites_page_view.dart';

/// 收藏页（对齐原项目 Favorites.vue）。
///
/// 平台切换、分类 Tab、拉取、点击打开、登录引导与文案**全部由
/// `CollectionPlatform` 注册表驱动**，本页不含任何具体平台分支。
/// 新增音源只需注册适配器。
class FavoritesPage extends ConsumerStatefulWidget {
  const FavoritesPage({super.key});

  @override
  ConsumerState<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends ConsumerState<FavoritesPage> {
  /// 当前平台 source / 分类 tab id；存于 [shell_page_state] provider
  /// （跨壳内容卸载/重挂载保留），State 重建时于 [initState] 恢复。
  late String _platform;
  late String _tab;

  /// 各 tab 缓存数据（key：`'$source.$tabId'`；切换保留，登录态变化时清空）。
  final Map<String, List<CoverItem>> _cache = {};
  final Map<String, String> _error = {};
  final Set<String> _loading = {};
  final Set<String> _loaded = {};

  CollectionPlatform get _adapter => collectionPlatform(_platform);

  /// 当前平台是否已登录（内容区据此显示数据或登录引导）。
  bool get _loggedIn => _adapter.loggedIn(ref);

  String get _cacheKey => _adapter.tabKey(_tab);

  @override
  void initState() {
    super.initState();
    // 恢复上次平台选择（壳内容因播放页展开被卸载后重建）；实验性音源已关闭
    // 时不保留 NK 选择（避免对其发请求）。
    var source = ref.read(favoritesPlatformProvider) ?? 'netease';
    if (source == 'neko' && !ref.read(appPrefsProvider).nekoEnabled) {
      source = 'netease';
    }
    _platform = source;
    final adapter = collectionPlatform(source);
    final restored = ref.read(adapter.tabSelection);
    _tab = (restored != null && adapter.tabIds.contains(restored))
        ? restored
        : adapter.defaultTabId;
    if (_loggedIn) _fetch();
  }

  void _clearCacheState() {
    _cache.clear();
    _error.clear();
    _loading.clear();
    _loaded.clear();
  }

  void _setPlatform(String source) {
    final adapter = collectionPlatform(source);
    ref.read(favoritesPlatformProvider.notifier).set(source);
    final restored = ref.read(adapter.tabSelection);
    setState(() {
      _platform = source;
      _tab = (restored != null && adapter.tabIds.contains(restored))
          ? restored
          : adapter.defaultTabId;
    });
  }

  void _setTab(String tabId) {
    ref.read(_adapter.tabSelection.notifier).set(tabId);
    setState(() => _tab = tabId);
  }

  void _markLoading(String key) {
    setState(() {
      _loading.add(key);
      _error.remove(key);
    });
  }

  @override
  Widget build(BuildContext context) => _buildFavoritesPage(context);
}
