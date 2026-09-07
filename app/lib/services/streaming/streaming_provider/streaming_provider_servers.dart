part of '../streaming_provider.dart';

mixin _StreamingNotifierServerActions on Notifier<StreamingState>, _StreamingNotifierCore {
  /// 启动初始化：如有激活服务器则后台自动连接（不阻塞首帧）。
  Future<void> _initImpl() async {
    final id = state.activeServerId;
    if (id == null) return;
    if (state.connected) return;
    await _connectImpl();
  }

  /// 生成新服务器配置并入库；首台服务器自动设为激活并连接。
  Future<void> _addServerImpl(StreamingServerInput input) async {
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
      await _setActiveServerImpl(cfg.id);
    } else {
      _persist();
    }
  }

  /// 更新服务器配置；若为当前激活服务器则按新配置重连（刷新 token）。
  Future<void> _updateServerImpl(String id, StreamingServerInput input) async {
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
      await _connectImpl();
    }
  }

  /// 删除服务器；删掉激活服务器时清空连接与浏览缓存。
  Future<void> _removeServerImpl(String id) async {
    if (state.serverById(id) == null) return;
    final wasActive = state.activeServerId == id;
    state = state.copyWith(
      servers: state.servers.where((s) => s.id != id).toList(),
      activeServerId: wasActive ? null : state.activeServerId,
    );
    _persist();
    if (wasActive) {
      await _disconnectImpl();
    }
  }

  /// 用表单数据测试连通性（不落库）。
  Future<StreamingPingResult> _testConnectionImpl(StreamingServerInput input) {
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
  Future<void> _setActiveServerImpl(String id) async {
    if (state.serverById(id) == null) return;
    final changed = state.activeServerId != id;
    state = state.copyWith(activeServerId: id);
    _persist();
    if (changed) {
      _resetBrowseCache();
      await _connectImpl();
    }
  }

  /// 连接当前激活服务器。
  ///
  /// Jellyfin/Emby 先鉴权换 accessToken/userId（回填配置），Subsonic 系
  /// 直接 ping；成功回填 lastConnected 并持久化。
  Future<void> _connectImpl() async {
    final cfg = state.activeServer;
    if (cfg == null) return;
    if (state.connecting) return;
    state = state.copyWith(connecting: true, connectionError: null);
    try {
      final client = StreamingClient(cfg);
      var working = cfg;
      if (needsAccessToken(cfg.type)) {
        final auth = await client.authenticate();
        working = cfg.copyWith(
          accessToken: auth.accessToken,
          userId: auth.userId,
        );
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
      working = working.copyWith(
        lastConnected: DateTime.now().millisecondsSinceEpoch,
      );
      state = state.copyWith(
        servers: [
          for (final s in state.servers) s.id == working.id ? working : s,
        ],
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
  Future<void> _disconnectImpl() async {
    state = state.copyWith(
      connected: false,
      connecting: false,
      connectionError: null,
      serverVersion: null,
    );
    _resetBrowseCache();
  }

  /// 清空全部服务器配置与连接状态并持久化（安全销毁流程调用；
  /// 随后文件本身被覆盖删除，此处落盘空列表仅保证内存态一致）。
  Future<void> _clearAllImpl() async {
    await _disconnectImpl();
    state = state.copyWith(servers: const [], activeServerId: null);
    _persist();
  }
}
