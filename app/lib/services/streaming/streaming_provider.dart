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
class StreamingNotifier extends Notifier<StreamingState> {
  /// 各 Tab 首次拉取是否已完成（懒加载去重）。
  bool _songsLoaded = false;
  bool _albumsLoaded = false;
  bool _artistsLoaded = false;
  bool _playlistsLoaded = false;

  /// 各 Tab 拉取互斥（防重复请求）。
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

  void _persist() {
    final s = state;
    StreamingStore.save(s.servers, s.activeServerId);
  }

  /// 启动初始化：如有激活服务器则后台自动连接（不阻塞首帧）。
  Future<void> init() async {
    final id = state.activeServerId;
    if (id == null) return;
    if (state.connected) return;
    await connect();
  }

  /// 生成新服务器配置并入库；首台服务器自动设为激活并连接。
  Future<void> addServer(StreamingServerInput input) async {
    final cfg = StreamingServerConfig(
      id: newUuid(),
      name: input.name.trim(),
      type: input.type,
      host: input.host.trim(),
      port: input.port,
      isArchoeraServer: input.isArchoeraServer,
      useHttps: input.useHttps,
      username: input.username.trim(),
      password: input.password,
    );
    state = state.copyWith(servers: [...state.servers, cfg]);
    if (state.activeServerId == null) {
      await setActiveServer(cfg.id);
    } else {
      _persist();
    }
  }

  /// 更新服务器配置；若为当前激活服务器则按新配置重连（刷新 token）。
  Future<void> updateServer(String id, StreamingServerInput input) async {
    final old = state.serverById(id);
    if (old == null) return;
    final updated = old.copyWith(
      name: input.name.trim(),
      type: input.type,
      host: input.host.trim(),
      port: input.port,
      isArchoeraServer: input.isArchoeraServer,
      useHttps: input.useHttps,
      username: input.username.trim(),
      password: input.password,
    );
    state = state.copyWith(
      servers: [for (final s in state.servers) s.id == id ? updated : s],
    );
    _persist();
    if (state.activeServerId == id) {
      await connect();
    }
  }

  /// 删除服务器；删掉激活服务器时清空连接与浏览缓存。
  Future<void> removeServer(String id) async {
    if (state.serverById(id) == null) return;
    final wasActive = state.activeServerId == id;
    state = state.copyWith(
      servers: state.servers.where((s) => s.id != id).toList(),
      activeServerId: wasActive ? null : state.activeServerId,
    );
    _persist();
    if (wasActive) {
      await disconnect();
    }
  }

  /// 用表单数据测试连通性（不落库）。
  Future<StreamingPingResult> testConnection(StreamingServerInput input) {
    final probe = StreamingServerConfig(
      id: 'probe',
      name: input.name,
      type: input.type,
      host: input.host.trim(),
      port: input.port,
      isArchoeraServer: input.isArchoeraServer,
      useHttps: input.useHttps,
      username: input.username.trim(),
      password: input.password,
    );
    return StreamingClient(probe).ping();
  }

  /// 切换激活服务器并连接。
  Future<void> setActiveServer(String id) async {
    if (state.serverById(id) == null) return;
    final changed = state.activeServerId != id;
    state = state.copyWith(activeServerId: id);
    _persist();
    if (changed) {
      // 切服务器后清空浏览缓存，各 Tab 重新按需拉取
      _songsLoaded = _albumsLoaded = _artistsLoaded = _playlistsLoaded = false;
      state = state.copyWith(
        songs: const [],
        albums: const [],
        artists: const [],
        playlists: const [],
      );
      await connect();
    }
  }

  /// 连接当前激活服务器。
  ///
  /// Jellyfin/Emby 先鉴权换 accessToken/userId（回填配置），Subsonic 系
  /// 直接 ping；成功回填 lastConnected 并持久化。
  Future<void> connect() async {
    final cfg = state.activeServer;
    if (cfg == null) return;
    if (state.connecting) return;
    state = state.copyWith(connecting: true, connectionError: null);
    try {
      final client = StreamingClient(cfg);
      var working = cfg;
      if (needsAccessToken(cfg.type)) {
        final auth = await client.authenticate();
        working = cfg.copyWith(accessToken: auth.accessToken, userId: auth.userId);
      }
      final ping = await StreamingClient(working).ping();
      if (!ping.ok) {
        state = state.copyWith(
          connecting: false,
          connected: false,
          connectionError: ping.error,
        );
        return;
      }
      working = working.copyWith(lastConnected: DateTime.now().millisecondsSinceEpoch);
      state = state.copyWith(
        servers: [for (final s in state.servers) s.id == working.id ? working : s],
        connecting: false,
        connected: true,
        connectionError: null,
        serverVersion: ping.version,
      );
      _persist();
    } catch (e) {
      state = state.copyWith(
        connecting: false,
        connected: false,
        connectionError: '$e',
      );
    }
  }

  /// 断开当前连接（清空浏览缓存）。
  Future<void> disconnect() async {
    state = state.copyWith(
      connected: false,
      connecting: false,
      connectionError: null,
      serverVersion: null,
      songs: const [],
      albums: const [],
      artists: const [],
      playlists: const [],
    );
    _songsLoaded = _albumsLoaded = _artistsLoaded = _playlistsLoaded = false;
  }

  StreamingClient? get _client {
    final cfg = state.activeServer;
    if (cfg == null || !state.connected) return null;
    return StreamingClient(cfg);
  }

  void _setLoading(bool v) => state = state.copyWith(loading: v);

  /// 拉歌曲列表（懒加载：首次或显式刷新才请求）。
  Future<void> fetchSongs({bool force = false}) async {
    final client = _client;
    if (client == null || _fetching) return;
    if (_songsLoaded && !force) return;
    _fetching = true;
    _setLoading(true);
    try {
      final songs = await client.listSongs();
      state = state.copyWith(songs: songs);
      _songsLoaded = true;
    } catch (_) {
      // 拉取失败保留旧数据；连接断开由 UI 空态提示
    } finally {
      _fetching = false;
      _setLoading(false);
    }
  }

  Future<void> fetchAlbums({bool force = false}) async {
    final client = _client;
    if (client == null || _fetching) return;
    if (_albumsLoaded && !force) return;
    _fetching = true;
    _setLoading(true);
    try {
      final albums = await client.listAlbums();
      state = state.copyWith(albums: albums);
      _albumsLoaded = true;
    } catch (_) {
    } finally {
      _fetching = false;
      _setLoading(false);
    }
  }

  Future<void> fetchArtists({bool force = false}) async {
    final client = _client;
    if (client == null || _fetching) return;
    if (_artistsLoaded && !force) return;
    _fetching = true;
    _setLoading(true);
    try {
      final artists = await client.listArtists();
      state = state.copyWith(artists: artists);
      _artistsLoaded = true;
    } catch (_) {
    } finally {
      _fetching = false;
      _setLoading(false);
    }
  }

  Future<void> fetchPlaylists({bool force = false}) async {
    final client = _client;
    if (client == null || _fetching) return;
    if (_playlistsLoaded && !force) return;
    _fetching = true;
    _setLoading(true);
    try {
      final playlists = await client.listPlaylists();
      state = state.copyWith(playlists: playlists);
      _playlistsLoaded = true;
    } catch (_) {
    } finally {
      _fetching = false;
      _setLoading(false);
    }
  }

  /// 顶栏刷新：强制重拉当前数据源（可指定 tab；null = 全部）。
  Future<void> refresh({String? tab}) async {
    switch (tab) {
      case 'songs':
        await fetchSongs(force: true);
      case 'albums':
        await fetchAlbums(force: true);
      case 'artists':
        await fetchArtists(force: true);
      case 'playlists':
        await fetchPlaylists(force: true);
      default:
        await Future.wait([
          fetchSongs(force: true),
          fetchAlbums(force: true),
          fetchArtists(force: true),
          fetchPlaylists(force: true),
        ]);
    }
  }

  /// 按 id 取当前服务器配置（详情页 / 播放解析共用）。
  StreamingServerConfig? serverConfigById(String id) => state.serverById(id);
}

/// 流媒体控制器 Provider。
final streamingProvider =
    NotifierProvider<StreamingNotifier, StreamingState>(StreamingNotifier.new);
