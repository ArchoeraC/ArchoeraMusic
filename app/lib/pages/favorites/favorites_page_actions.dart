// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../favorites_page.dart';

// ignore_for_file: invalid_use_of_protected_member

extension _FavoritesPageActions on _FavoritesPageState {
  /// 登录态变化（登录成功 / 退出）时清空缓存并刷新。
  void _onAuthChanged() {
    _clearCacheState();
    if (_loggedIn) _fetch();
  }

  void _switchPlatform(String source) {
    if (source == _platform) return;
    _setPlatform(source);
    if (_loggedIn && !_loaded.contains(_cacheKey)) _fetch();
  }

  void _switchTab(String tabId) {
    if (tabId == _tab) return;
    _setTab(tabId);
    if (_loggedIn && !_loaded.contains(_cacheKey)) _fetch();
  }

  /// 拉取当前分类：适配器可一次请求填充多个分类（返回 map），这里统一
  /// 合并缓存并按返回的 key 标记已加载。
  Future<void> _fetch() async {
    final adapter = _adapter;
    final key = _cacheKey;
    if (_loading.contains(key)) return;
    _markLoading(key);
    try {
      final result = await adapter.fetchFavorites(ref, _tab);
      if (!mounted) return;
      setState(() {
        _cache.addAll(result);
        _loading.remove(key);
        _error.remove(key);
        _loaded.addAll(result.keys);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error[key] = '$e';
        _loading.remove(key);
        _loaded.add(key);
      });
    }
  }

  void _onCoverTap(CoverItem item) =>
      _adapter.openFavorite(context, ref, _tab, item);

  Future<void> _login() => _adapter.login(context);
}
