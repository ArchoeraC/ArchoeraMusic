// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 流媒体状态管理层（UI 单一数据源，对齐 stores/streaming.ts）。
///
/// 职责：
///   - 服务器列表 + 当前激活服务器（StreamingStore 持久化）
///   - 连接状态机：未配置 → 已配置未连接 → 已连接（含版本号）
///   - 四个浏览 Tab 的懒加载缓存：歌曲 / 专辑 / 歌手 / 歌单
/// 数据经 [StreamingClient] 分发到具体协议（Subsonic 家族 / Jellyfin / Emby）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../netease/track.dart';
import 'streaming_client.dart';
import 'streaming_models.dart';
import 'streaming_session.dart';
import 'streaming_store.dart';
import 'streaming_types.dart';

part 'streaming_provider/streaming_provider_core.dart';
part 'streaming_provider/streaming_provider_servers.dart';
part 'streaming_provider/streaming_provider_fetch.dart';

/// 流媒体 UI 状态。
class StreamingState {
  const StreamingState({
    this.servers = const [],
    this.activeServerId,
    this.connected = false,
    this.connecting = false,
    this.connectionError,
    this.serverVersion,
    this.loading = false,
    this.songs = const [],
    this.albums = const [],
    this.artists = const [],
    this.playlists = const [],
  });

  /// 已配置的服务器（持久化顺序）。
  final List<StreamingServerConfig> servers;

  /// 当前激活服务器 id（null = 未选择）。
  final String? activeServerId;

  /// 激活服务器是否已连接成功。
  final bool connected;

  /// 正在连接 / 正在切换服务器。
  final bool connecting;

  /// 连接失败描述（仅未连接时有意义）。
  final String? connectionError;

  /// 连接成功的服务器版本号。
  final String? serverVersion;

  /// 任意 Tab 拉取中（顶栏刷新按钮旋转）。
  final bool loading;

  /// 歌曲缓存（Tracks tab）。
  final List<Track> songs;

  /// 专辑缓存。
  final List<StreamingAlbum> albums;

  /// 歌手缓存。
  final List<StreamingArtist> artists;

  /// 歌单缓存。
  final List<StreamingPlaylist> playlists;

  StreamingServerConfig? get activeServer {
    final id = activeServerId;
    if (id == null) return null;
    for (final s in servers) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// 按 id 查服务器。
  StreamingServerConfig? serverById(String id) {
    for (final s in servers) {
      if (s.id == id) return s;
    }
    return null;
  }

  bool get hasServers => servers.isNotEmpty;

  StreamingState copyWith({
    List<StreamingServerConfig>? servers,
    Object? activeServerId = _unset,
    bool? connected,
    bool? connecting,
    Object? connectionError = _unset,
    Object? serverVersion = _unset,
    bool? loading,
    List<Track>? songs,
    List<StreamingAlbum>? albums,
    List<StreamingArtist>? artists,
    List<StreamingPlaylist>? playlists,
  }) {
    return StreamingState(
      servers: servers ?? this.servers,
      activeServerId: identical(activeServerId, _unset)
          ? this.activeServerId
          : activeServerId as String?,
      connected: connected ?? this.connected,
      connecting: connecting ?? this.connecting,
      connectionError: identical(connectionError, _unset)
          ? this.connectionError
          : connectionError as String?,
      serverVersion: identical(serverVersion, _unset)
          ? this.serverVersion
          : serverVersion as String?,
      loading: loading ?? this.loading,
      songs: songs ?? this.songs,
      albums: albums ?? this.albums,
      artists: artists ?? this.artists,
      playlists: playlists ?? this.playlists,
    );
  }

  static const Object _unset = Object();
}

/// 流媒体控制器（Notifier）。
class StreamingNotifier extends Notifier<StreamingState>
    with
        _StreamingNotifierCore,
        _StreamingNotifierServerActions,
        _StreamingNotifierFetchActions {
  /// 各 Tab 首次拉取是否已完成（懒加载去重）。
  @override
  bool _songsLoaded = false;
  @override
  bool _albumsLoaded = false;
  @override
  bool _artistsLoaded = false;
  @override
  bool _playlistsLoaded = false;

  /// 各 Tab 拉取互斥（防重复请求）。
  @override
  bool _fetching = false;

  @override
  StreamingState build() {
    final loaded = StreamingStore.load();
    final servers = loaded.servers;
    return StreamingState(
      servers: servers,
      activeServerId: loaded.activeServerId,
    );
  }

  /// autoDispose 保活包装：这些操作由页面 / 设置以 `ref.read(notifier)` 触发，
  /// 且多在网络 await 之后写 `state`；若页面在其间卸载，provider 会被释放、后续
  /// `state=` 将抛 UnmountedRefException。操作期间持有保活链接，完成后再交还释放
  /// （此时若无监听才真正卸载）。
  Future<T> _keepAliveDuring<T>(Future<T> Function() run) async {
    final link = ref.keepAlive();
    try {
      return await run();
    } finally {
      link.close();
    }
  }

  Future<void> init() => _keepAliveDuring(_initImpl);

  Future<void> addServer(StreamingServerInput input) =>
      _keepAliveDuring(() => _addServerImpl(input));

  Future<void> updateServer(String id, StreamingServerInput input) =>
      _keepAliveDuring(() => _updateServerImpl(id, input));

  Future<void> removeServer(String id) =>
      _keepAliveDuring(() => _removeServerImpl(id));

  Future<StreamingPingResult> testConnection(StreamingServerInput input) =>
      _keepAliveDuring(() => _testConnectionImpl(input));

  Future<void> setActiveServer(String id) =>
      _keepAliveDuring(() => _setActiveServerImpl(id));

  Future<void> connect() => _keepAliveDuring(_connectImpl);

  Future<void> disconnect() => _keepAliveDuring(_disconnectImpl);

  Future<void> clearAll() => _keepAliveDuring(_clearAllImpl);

  StreamingServerConfig? serverConfigById(String id) => state.serverById(id);

  Future<void> fetchSongs({bool force = false}) =>
      _keepAliveDuring(() => _fetchSongsImpl(force: force));

  Future<void> fetchAlbums({bool force = false}) =>
      _keepAliveDuring(() => _fetchAlbumsImpl(force: force));

  Future<void> fetchArtists({bool force = false}) =>
      _keepAliveDuring(() => _fetchArtistsImpl(force: force));

  Future<void> fetchPlaylists({bool force = false}) =>
      _keepAliveDuring(() => _fetchPlaylistsImpl(force: force));

  Future<void> refresh({String? tab}) =>
      _keepAliveDuring(() => _refreshImpl(tab: tab));
}

/// 流媒体控制器 Provider。
///
/// autoDispose：状态（服务器列表 / 连接态 / 四个 Tab 的懒加载缓存）由流媒体页
/// 与设置面板按需 `ref.watch` 持有；页面子树卸载（后台卸载页面 / 播放页展开）后
/// 释放内存。播放中的服务器配置与鉴权 token 已落盘（`StreamingStore`），播放
/// 途中的 `resolvePlayUrl` / 歌词来源仅同步读取 `serverConfigById`，按需从磁盘
/// 重建即可，不依赖内存连接态跨页常驻。
final streamingProvider =
    NotifierProvider.autoDispose<StreamingNotifier, StreamingState>(
      StreamingNotifier.new,
    );
