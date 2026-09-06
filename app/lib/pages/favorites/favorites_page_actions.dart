// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../favorites_page.dart';

extension _FavoritesPageActions on _FavoritesPageState {
  /// 登录态变化（登录成功 / 退出）时清空缓存并刷新。
  void _onAuthChanged() {
    _clearCacheState();
    if (_loggedIn) _fetch();
  }

  void _switchPlatform(_Platform platform) {
    if (platform == _platform) return;
    _setPlatform(platform);
    if (_loggedIn && !_loaded.contains(_cacheKey)) _fetch();
  }

  void _switchTab(_FavTab tab) {
    if (tab == _tab) return;
    _setFavTab(tab);
    if (_loggedIn && !_loaded.contains(_cacheKey)) _fetch();
  }

  void _switchKgTab(_KgTab tab) {
    if (tab == _kgTab) return;
    _setKgTab(tab);
    if (_loggedIn && !_loaded.contains(_cacheKey)) _fetch();
  }

  Future<void> _fetch() async {
    final key = _cacheKey;
    if (_loading.contains(key)) return;
    _markLoading(key);
    try {
      if (_platform == _Platform.kugou) {
        final lib = await ref.read(kugouApiProvider).userLibrary();
        // 一次拉取填充全部分类（切换 tab 不再重复请求）
        _cache['kugou.created'] = lib.createdPlaylists
            .map((i) => i.toCoverItem())
            .toList();
        _cache['kugou.collectedPlaylist'] = lib.collectedPlaylists
            .map((i) => i.toCoverItem())
            .toList();
        _cache['kugou.collectedAlbum'] = lib.collectedAlbums
            .map((i) => i.toCoverItem())
            .toList();
      } else {
        final account = ref.read(neteaseAuthProvider);
        final api = ref.read(neteaseApiProvider);
        final List<CoverItem> items;
        switch (_tab) {
          case _FavTab.playlist:
            final playlists = await api.userPlaylists(account!.userId);
            items = playlists
                .where((p) => p.subscribed)
                .map(
                  (p) => CoverItem(
                    id: p.id,
                    title: p.name,
                    cover: p.cover,
                    subtitle: p.owner ?? '',
                    trackCount: p.trackCount,
                  ),
                )
                .toList();
          case _FavTab.album:
            items = await api.albumSublist();
          case _FavTab.artist:
            items = await api.artistSublist();
        }
        _cache[key] = items;
      }
      if (!mounted) return;
      _finishFetchSuccess(key);
    } catch (e) {
      if (!mounted) return;
      _finishFetchError(key, e);
    }
  }

  void _onCoverTap(CoverItem item) {
    if (_platform == _Platform.kugou) {
      // 「我喜欢」为个人歌单，走 likedTracks 个人链路（listid→
      // /v4/get_list_all_file）；其余歌单/收藏专辑统一用公开歌单接口
      // 打开（global_collection_id；对齐 MoeKoeMusic 跳转 PlaylistDetail）
      if (item.title == '我喜欢') {
        showKugouTracksDialog(
          context,
          title: item.title,
          cover: item.cover,
          loadTracks: (ref) => ref.read(kugouApiProvider).likedTracks(),
        );
        return;
      }
      showKugouPlaylistDetailDialog(context, item);
      return;
    }
    switch (_tab) {
      case _FavTab.playlist:
        showPlaylistDetailDialog(context, item);
      case _FavTab.album:
        showNeteaseAlbumDialog(context, item);
      case _FavTab.artist:
        showNeteaseArtistDialog(context, item);
    }
  }

  Future<void> _login() async {
    if (_platform == _Platform.kugou) {
      await showDialog<bool>(
        context: context,
        barrierColor: Colors.black.withValues(alpha: 0.5),
        barrierDismissible: false,
        builder: (_) => const KgQrLoginDialog(),
      );
    } else {
      showNeteaseLoginDialog(context);
    }
  }
}
