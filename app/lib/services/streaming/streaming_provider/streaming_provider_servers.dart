// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

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
  /// 凭据直接写穿 vault 缓存，状态只保留非敏感元数据（不驻留明文）。
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
    StreamingStore.saveSecret(cfg.id, password: input.password);
    state = state.copyWith(servers: [...state.servers, cfg.withoutSecrets()]);
    if (state.activeServerId == null) {
      await _setActiveServerImpl(cfg.id);
    } else {
      _persist();
    }
  }

  /// 更新服务器配置；若为当前激活服务器则按新配置重连（刷新 token）。
  /// 凭据合并写入 vault（先 loadSecret 确保既有 token 不被覆盖），
  /// 状态只保留非敏感元数据。
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
    );
    await StreamingStore.loadSecret(id); // 确保缓存含既有凭据（保留 token）
    StreamingStore.saveSecret(id, password: input.password);
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
    }
    // 同一服务器在「断开连接」后再次点击「连接」也要重连（changed 为 false，
    // 仅凭 changed 判断会变成空操作，表现即「断开后无法重新连接」）。
    if (changed || !state.connected) {
      await _connectImpl();
    }
  }

  /// 连接当前激活服务器。
  ///
  /// Jellyfin/Emby 先鉴权换 accessToken/userId（回填配置），Subsonic 系
  /// 直接 ping；成功回填 lastConnected 并持久化。
  Future<void> _connectImpl() async {
    final base = state.activeServer;
    if (base == null) return;
    if (state.connecting) return;
    state = state.copyWith(connecting: true, connectionError: null);
    try {
      // 凭据按需解密（不在启动时批量进堆）；仅本次连接临时持有。
      await StreamingStore.loadSecret(base.id);
      var working = _mergeSecret(state.serverById(base.id) ?? base);
      final client = StreamingClient(working);
      if (needsAccessToken(working.type)) {
        final auth = await client.authenticate();
        working = working.copyWith(
          accessToken: auth.accessToken,
          userId: auth.userId,
        );
        // 鉴权 token 直接落 vault（合并，不写入长驻状态）
        StreamingStore.saveSecret(base.id, accessToken: auth.accessToken);
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
      // 状态只回填非敏感元数据（password/accessToken 剥除）
      final meta = working.withoutSecrets();
      state = state.copyWith(
        servers: [
          for (final s in state.servers) s.id == meta.id ? meta : s,
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
