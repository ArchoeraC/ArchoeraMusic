// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// MCP 控制服务：本地回环 HTTP 监听 + MCP / REST / WebSocket 三入口生命周期。
///
/// 设计要点：
/// - 默认关闭；开启后仅绑定 `127.0.0.1`，普通用户即可运行（非特权端口）。
/// - 配置由偏好派生（[mcpConfigOf]），值变化即重启监听；
///   能力组默认全关，关闭时对应工具/路由不可见。
/// - WebSocket 以 JSON-RPC 2.0 双向通信，服务端主动推送播放状态变化通知。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../stores/app_prefs.dart';
import '../log/log.dart';
import '../playback/playback_notifier.dart';
import '../playback/playback_state.dart';
import 'mcp_tools.dart';
import 'mcp_http.dart';
import 'mcp_protocol.dart';
import 'mcp_models.dart';

/// 由偏好派生服务配置（供宿主与设置页复用）。
McpConfig mcpConfigOf(AppPrefs prefs) => McpConfig(
  enabled: prefs.mcpEnabled,
  port: prefs.mcpPort,
  accessKey: prefs.mcpAccessKey,
  allowKeyless: prefs.mcpAllowKeyless,
  allowLan: prefs.mcpAllowLan,
  capabilities: {
    for (final capability in McpCapability.values)
      if (prefs.mcpCapabilityEnabled(capability.id)) capability,
  },
);

/// 生成新的访问密钥（128-bit 十六进制；首次开启或手动重置时使用）。
String generateMcpAccessKey() {
  final rng = Random.secure();
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// 应用根作用域内的唯一 MCP 控制服务实例。
final mcpServiceProvider = Provider<McpService>((ref) {
  final service = McpService(ref);
  ref.onDispose(service.dispose);
  return service;
});

/// MCP 控制服务。
class McpService extends ChangeNotifier {
  McpService(this._ref) {
    _api = McpActions(_ref, _tracks);
    _tools = buildMcpTools(_api);
    _mcp = McpRpcHandler(tools: () => _tools, config: () => _config, api: _api);
    _http = McpHttpHandler(
      config: () => _config,
      tools: () => _tools,
      api: _api,
      mcp: _mcp,
      onWebSocketUpgrade: _upgradeWebSocket,
    );
  }

  final Ref _ref;
  final McpTrackCache _tracks = McpTrackCache();
  late final McpActions _api;
  late final List<McpTool> _tools;
  late final McpRpcHandler _mcp;
  late final McpHttpHandler _http;

  McpConfig _config = McpConfig.disabled;
  HttpServer? _server;
  ProviderSubscription<PlaybackState>? _playbackSub;
  final Set<_WsClient> _clients = <_WsClient>{};

  String _lastSignature = '';
  DateTime _lastPositionAt = DateTime.fromMillisecondsSinceEpoch(0);
  String? _lastError;

  /// 是否正在监听。
  bool get running => _server != null;

  /// 实际绑定端口（未运行为 null）。
  int? get boundPort => _server?.port;

  /// 实际绑定地址（未运行为 null；局域网模式为 `0.0.0.0`）。
  String? get boundHost => _server?.address.address;

  /// 是否处于局域网暴露模式。
  bool get lanExposed => running && _config.allowLan;

  /// 最近一次启动失败信息（成功启动后清空）。
  String? get lastError => _lastError;

  /// 已连接的 WebSocket 客户端数。
  int get wsClientCount => _clients.length;

  /// 应用最新配置（幂等；配置未变且运行态一致时直接返回）。
  ///
  /// 所有调用经单一 Future 链串行化：偏好写入会同步触发再次回调，
  /// 串行可避免重启监听时的「关闭/绑定」交错竞态。
  Future<void> apply(McpConfig config) {
    final next = _queue.then((_) => _apply(config));
    _queue = next.catchError((_) {});
    return next;
  }

  Future<void> _queue = Future<void>.value();

  Future<void> _apply(McpConfig config) async {
    var next = config;
    if (next.enabled && next.accessKey.isEmpty) {
      final key = generateMcpAccessKey();
      _ref.read(appPrefsProvider.notifier).setMcpAccessKey(key);
      next = next.copyWith(accessKey: key);
    }
    if (_config == next && running) return;
    if (_config == next && !next.enabled && !running) return;
    _config = next;
    await _restart();
  }

  Future<void> _restart() async {
    await _stop();
    if (!_config.enabled) {
      notifyListeners();
      return;
    }
    try {
      final address = _config.allowLan
          ? InternetAddress.anyIPv4
          : InternetAddress.loopbackIPv4;
      final server = await HttpServer.bind(address, _config.port);
      _server = server;
      _lastError = null;
      _mcp.reset();
      server.listen(
        _handle,
        onError: (Object error, StackTrace stack) =>
            Log.w('mcp', 'HTTP 连接错误: $error'),
      );
      _playbackSub = _ref.listen<PlaybackState>(
        playbackProvider,
        (_, next) => _onPlaybackChanged(next),
      );
      Log.i(
        'mcp',
        'MCP 控制服务已启动: http://${_config.allowLan ? '0.0.0.0' : '127.0.0.1'}:'
            '${_config.port}'
            '（能力: ${_config.capabilities.map((c) => c.id).join(',')}）',
      );
    } catch (e) {
      _server = null;
      _lastError = '$e';
      Log.e('mcp', 'MCP 控制服务启动失败（端口 ${_config.port}）: $e');
    }
    notifyListeners();
  }

  Future<void> _stop() async {
    _playbackSub?.close();
    _playbackSub = null;
    for (final client in _clients.toList()) {
      try {
        await client.socket.close();
      } catch (_) {
        // 连接可能已断开，忽略。
      }
    }
    _clients.clear();
    final server = _server;
    _server = null;
    if (server != null) {
      await server.close(force: true);
    }
  }

  Future<void> _handle(HttpRequest request) => _http.handle(request);

  @override
  void dispose() {
    unawaited(_stop());
    super.dispose();
  }

  // ── WebSocket ─────────────────────────────────────────────────

  Future<void> _upgradeWebSocket(HttpRequest request) async {
    final socket = await WebSocketTransformer.upgrade(request);
    final client = _WsClient(socket);
    _clients.add(client);
    _send(client, {
      'jsonrpc': '2.0',
      'method': 'server.hello',
      'params': {
        'server': 'archoera-music',
        'protocolVersion': kMcpPreferredVersion,
        'capabilities': [
          for (final c in McpCapability.values)
            if (_config.has(c)) c.id,
        ],
      },
    });
    socket.listen(
      (data) => _onWsMessage(client, data),
      onError: (_) => _removeClient(client),
      onDone: () => _removeClient(client),
      cancelOnError: true,
    );
  }

  void _onWsMessage(_WsClient client, Object? data) {
    if (data is! String) return;
    Object? decoded;
    try {
      decoded = jsonDecode(data);
    } catch (_) {
      _wsError(client, null, -32700, 'Parse error');
      return;
    }
    if (decoded is! Map) {
      _wsError(client, null, -32600, 'Invalid Request');
      return;
    }
    final message = Map<String, dynamic>.from(decoded);
    final method = message['method'];
    if (method is! String) {
      if (message.containsKey('id')) {
        _wsError(client, message['id'], -32600, 'Invalid Request');
      }
      return;
    }
    // 客户端通知（无 id）无需应答。
    if (!message.containsKey('id')) return;
    final params = message['params'] is Map
        ? Map<String, dynamic>.from(message['params'] as Map)
        : <String, dynamic>{};
    unawaited(_invokeWs(client, message['id'], method, params));
  }

  Future<void> _invokeWs(
    _WsClient client,
    Object? id,
    String method,
    Map<String, dynamic> params,
  ) async {
    final tool = _tools.where((t) => t.name == method).firstOrNull;
    if (tool == null || !_config.has(tool.capability)) {
      _wsError(client, id, -32601, '未实现或未启用的方法: $method');
      return;
    }
    try {
      final result = await tool.handle(params);
      _send(client, {'jsonrpc': '2.0', 'id': id, 'result': result});
    } on McpActionException catch (e) {
      _wsError(client, id, -32602, '${e.code}: ${e.message}');
    } catch (e) {
      _wsError(client, id, -32603, '$e');
    }
  }

  void _onPlaybackChanged(PlaybackState state) {
    if (_clients.isEmpty) return;
    final signature = [
      state.playing,
      state.buffering,
      state.track?.source,
      state.track?.id,
      state.queueIndex,
      state.queue.length,
      state.repeatMode,
      state.shuffle,
      state.volume,
    ].join('|');
    if (signature != _lastSignature) {
      _lastSignature = signature;
      _broadcast('player.state', playbackStateToJson(state));
      return;
    }
    final now = DateTime.now();
    if (now.difference(_lastPositionAt) >= const Duration(seconds: 1)) {
      _lastPositionAt = now;
      _broadcast('player.position', {
        'positionMs': state.position.inMilliseconds,
        'durationMs': state.duration.inMilliseconds,
      });
    }
  }

  void _broadcast(String method, Map<String, Object?> params) {
    final encoded = jsonEncode({
      'jsonrpc': '2.0',
      'method': method,
      'params': params,
    });
    for (final client in _clients.toList()) {
      try {
        client.socket.add(encoded);
      } catch (_) {
        _removeClient(client);
      }
    }
  }

  void _send(_WsClient client, Map<String, Object?> message) {
    try {
      client.socket.add(jsonEncode(message));
    } catch (_) {
      _removeClient(client);
    }
  }

  void _wsError(_WsClient client, Object? id, int code, String message) {
    _send(client, {
      'jsonrpc': '2.0',
      'id': id,
      'error': {'code': code, 'message': message},
    });
  }

  void _removeClient(_WsClient client) {
    _clients.remove(client);
  }
}

class _WsClient {
  _WsClient(this.socket);

  final WebSocket socket;
}
