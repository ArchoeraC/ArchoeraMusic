// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../streaming_provider.dart';

mixin _StreamingNotifierCore on Notifier<StreamingState> {
  bool get _songsLoaded;
  set _songsLoaded(bool value);

  bool get _albumsLoaded;
  set _albumsLoaded(bool value);

  bool get _artistsLoaded;
  set _artistsLoaded(bool value);

  bool get _playlistsLoaded;
  set _playlistsLoaded(bool value);

  void _persist() {
    final s = state;
    StreamingStore.save(s.servers, s.activeServerId);
  }

  void _resetBrowseCache() {
    _songsLoaded = false;
    _albumsLoaded = false;
    _artistsLoaded = false;
    _playlistsLoaded = false;
    state = state.copyWith(
      songs: const [],
      albums: const [],
      artists: const [],
      playlists: const [],
    );
  }

  /// 合并当前内存缓存中**已加载**的凭据（未加载则原样返回，不触发解密）。
  StreamingServerConfig _mergeSecret(StreamingServerConfig cfg) {
    final sec = StreamingStore.cachedSecret(cfg.id);
    if (sec == null) return cfg;
    final password = sec['password'];
    return cfg.copyWith(
      password: (password != null && password.isNotEmpty)
          ? password
          : cfg.password,
      accessToken: sec['accessToken'] ?? cfg.accessToken,
    );
  }

  /// 解析激活服务器为「带凭据」的客户端：凭据按需经 [StreamingStore.loadSecret]
  /// 解密，随后仅在本次调用内临时持有（不写回 [StreamingState]）。
  Future<StreamingClient?> _resolvedClient() async {
    final cfg = state.activeServer;
    if (cfg == null || !state.connected) return null;
    await StreamingStore.loadSecret(cfg.id);
    return StreamingClient(_mergeSecret(cfg));
  }

  /// 解析指定服务器为「带凭据」配置（异步；凭据按需解密，不写回状态）。
  Future<StreamingServerConfig?> _resolvedServerImpl(String id) async {
    final base = state.serverById(id);
    if (base == null) return null;
    await StreamingStore.loadSecret(id);
    return _mergeSecret(base);
  }

  void _setLoading(bool value) => state = state.copyWith(loading: value);
}
