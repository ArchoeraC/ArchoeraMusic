// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// MCP 控制服务的 HTTP 入口：REST（`/api/*`）+ MCP（`/mcp`）+ WebSocket 升级。
///
/// 安全基线（普通用户即可满足，无需提权）：
/// - 仅监听 `127.0.0.1`（由服务绑定决定）；
/// - 除 `/` 与 `/api/health` 外均校验访问密钥；
/// - 校验 `Origin`，阻断 DNS rebinding（规范强制）。
library;

import 'dart:convert';
import 'dart:io';

import 'mcp_tools.dart';
import 'mcp_protocol.dart';
import 'mcp_models.dart';

/// 逐请求处理 HTTP（无内部状态；配置/工具目录由服务实时提供）。
class McpHttpHandler {
  McpHttpHandler({
    required this.config,
    required this.tools,
    required this.api,
    required this.mcp,
    required this.onWebSocketUpgrade,
  });

  final McpConfig Function() config;
  final List<McpTool> Function() tools;
  final McpActions api;
  final McpRpcHandler mcp;

  /// WebSocket 升级回调（服务接管连接，本处理器不再关闭响应）。
  final Future<void> Function(HttpRequest request) onWebSocketUpgrade;

  Future<void> handle(HttpRequest request) async {
    final response = request.response;
    try {
      _applyCors(request, response);
      if (request.method == 'OPTIONS') {
        response.statusCode = HttpStatus.noContent;
        await response.close();
        return;
      }
      if (!_originAllowed(request.headers.value('origin'))) {
        await _json(
          response,
          HttpStatus.forbidden,
          _error('forbidden', 'Origin 不被允许'),
        );
        return;
      }

      final path = request.uri.path;
      if (path == '/' || path.isEmpty) {
        await _json(response, HttpStatus.ok, _rootPayload());
        return;
      }
      if (path == '/api/health' && request.method == 'GET') {
        await _json(response, HttpStatus.ok, const {'status': 'ok'});
        return;
      }
      if (!_authorized(request)) {
        await _json(
          response,
          HttpStatus.unauthorized,
          _error('unauthorized', '缺少或无效的访问密钥（X-Archoera-Key）'),
        );
        return;
      }
      if (path == '/mcp') {
        await _handleMcp(request, response);
        return;
      }
      if (path == '/ws') {
        if (!WebSocketTransformer.isUpgradeRequest(request)) {
          await _json(
            response,
            HttpStatus.upgradeRequired,
            _error('upgrade_required', 'WebSocket 需要 Upgrade 请求'),
          );
          return;
        }
        await onWebSocketUpgrade(request);
        return;
      }
      if (path == '/api' || path.startsWith('/api/')) {
        await _handleRest(request, response);
        return;
      }
      await _json(
        response,
        HttpStatus.notFound,
        _error('not_found', '未知路径: $path'),
      );
    } catch (e) {
      try {
        await _json(
          response,
          HttpStatus.internalServerError,
          _error('internal', '服务器错误: $e'),
        );
      } catch (_) {
        // 响应可能已随连接关闭，忽略。
      }
    }
  }

  // ── 安全 ──────────────────────────────────────────────────────

  bool _authorized(HttpRequest request) {
    final cfg = config();
    if (cfg.allowKeyless || cfg.accessKey.isEmpty) return true;
    final headerKey = request.headers.value('x-archoera-key');
    final bearer = _bearer(request.headers.value('authorization'));
    return constantTimeEquals(headerKey ?? bearer, cfg.accessKey);
  }

  static String? _bearer(String? authorization) {
    if (authorization == null) return null;
    const prefix = 'Bearer ';
    if (authorization.length <= prefix.length) return null;
    if (authorization.substring(0, prefix.length).toLowerCase() !=
        prefix.toLowerCase()) {
      return null;
    }
    return authorization.substring(prefix.length).trim();
  }

  bool _originAllowed(String? origin) {
    if (origin == null || origin.isEmpty) return true; // 原生客户端通常无 Origin
    final uri = Uri.tryParse(origin);
    if (uri == null) return false;
    final host = uri.host;
    return host == 'localhost' ||
        host == '127.0.0.1' ||
        host == '::1' ||
        host == '[::1]';
  }

  void _applyCors(HttpRequest request, HttpResponse response) {
    final origin = request.headers.value('origin');
    if (origin != null && _originAllowed(origin)) {
      response.headers.set('Access-Control-Allow-Origin', origin);
      response.headers.set('Vary', 'Origin');
    }
    response.headers.set(
      'Access-Control-Allow-Methods',
      'GET, POST, PUT, DELETE, OPTIONS',
    );
    response.headers.set(
      'Access-Control-Allow-Headers',
      'Content-Type, Authorization, X-Archoera-Key, Mcp-Session-Id, MCP-Protocol-Version',
    );
    response.headers.set('Access-Control-Expose-Headers', 'Mcp-Session-Id');
  }

  // ── MCP ───────────────────────────────────────────────────────

  Future<void> _handleMcp(HttpRequest request, HttpResponse response) async {
    final sessionId = request.headers.value('mcp-session-id');
    final protocolVersion = request.headers.value('mcp-protocol-version');
    if (protocolVersion != null &&
        protocolVersion.isNotEmpty &&
        !kMcpSupportedVersions.contains(protocolVersion)) {
      await _json(response, HttpStatus.badRequest, {
        'jsonrpc': '2.0',
        'id': null,
        'error': {
          'code': -32600,
          'message': '不支持的 MCP-Protocol-Version: $protocolVersion',
        },
      });
      return;
    }
    switch (request.method) {
      case 'POST':
        final raw = await _readBody(request);
        Object? decoded;
        if (raw.trim().isNotEmpty) {
          try {
            decoded = jsonDecode(raw);
          } catch (_) {
            await _json(response, HttpStatus.badRequest, {
              'jsonrpc': '2.0',
              'id': null,
              'error': {'code': -32700, 'message': 'Parse error'},
            });
            return;
          }
        }
        final result = await mcp.handleMessage(decoded, sessionId: sessionId);
        await _writeMcp(response, result);
      case 'GET':
        await _writeMcp(response, mcp.getStreamResult());
      case 'DELETE':
        await _writeMcp(response, mcp.deleteSession(sessionId));
      default:
        response.statusCode = HttpStatus.methodNotAllowed;
        response.headers.set('Allow', 'POST, GET, DELETE');
        await response.close();
    }
  }

  Future<void> _writeMcp(HttpResponse response, McpHttpResult result) async {
    response.statusCode = result.status;
    result.headers.forEach((key, value) => response.headers.set(key, value));
    if (result.body != null) {
      response.headers.contentType = ContentType(
        'application',
        'json',
        charset: 'utf-8',
      );
      response.write(jsonEncode(result.body));
    }
    await response.close();
  }

  // ── REST ──────────────────────────────────────────────────────

  Future<void> _handleRest(HttpRequest request, HttpResponse response) async {
    final segments = request.uri.pathSegments; // ['api', ...]
    final method = request.method;
    Map<String, dynamic> body = const {};
    if (method == 'POST' ||
        method == 'PUT' ||
        method == 'PATCH' ||
        method == 'DELETE') {
      final raw = await _readBody(request);
      if (raw.trim().isNotEmpty) {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is! Map) {
            await _json(
              response,
              HttpStatus.badRequest,
              _error('invalid_body', '请求体必须是 JSON 对象'),
            );
            return;
          }
          body = Map<String, dynamic>.from(decoded);
        } catch (_) {
          await _json(
            response,
            HttpStatus.badRequest,
            _error('invalid_json', '请求体不是合法 JSON'),
          );
          return;
        }
      }
    }

    try {
      final result = await _route(segments, method, request, body);
      if (result == null) {
        await _json(
          response,
          HttpStatus.notFound,
          _error('not_found', '未知接口: $method ${request.uri.path}'),
        );
        return;
      }
      await _json(response, HttpStatus.ok, result);
    } on McpActionException catch (e) {
      await _json(response, _statusFor(e.code), _error(e.code, e.message));
    } catch (e) {
      await _json(
        response,
        HttpStatus.internalServerError,
        _error('internal', '服务器错误: $e'),
      );
    }
  }

  /// 返回 null 表示未匹配到路由。
  Future<Object?> _route(
    List<String> segments,
    String method,
    HttpRequest request,
    Map<String, dynamic> body,
  ) {
    if (segments.length < 2) return Future.value(null);
    final q = request.uri.queryParameters;

    // /api/info | /api/status | /api/now-playing | /api/preferences
    if (segments.length == 2) {
      switch (segments[1]) {
        case 'info':
          if (method == 'GET') return Future.value(_info());
          return Future.value(null);
        case 'status':
          if (method == 'GET') return _invoke('get_status', const {});
          return Future.value(null);
        case 'now-playing':
          if (method == 'GET') return _invoke('get_now_playing', const {});
          return Future.value(null);
        case 'queue':
          if (method == 'GET') return _invoke('get_queue', const {});
          if (method == 'DELETE') return _invoke('queue_clear', const {});
          return Future.value(null);
        case 'preferences':
          if (method == 'GET') {
            final keys = q['keys']
                ?.split(',')
                .where((k) => k.isNotEmpty)
                .toList();
            return _invoke('get_preferences', {'keys': ?keys});
          }
          return Future.value(null);
        case 'tools':
          if (method == 'GET') return Future.value(_toolCatalog());
          return Future.value(null);
        case 'search':
          if (method == 'GET') {
            return _invoke('search_online', {
              'source': q['source'],
              'query': q['q'] ?? q['query'],
              if (q['limit'] != null) 'limit': _intOrNull(q['limit']),
              if (q['page'] != null) 'page': _intOrNull(q['page']),
            });
          }
          return Future.value(null);
        case 'library':
          return Future.value(null);
        case 'player':
          if (method == 'GET') return _invoke('get_status', const {});
          return Future.value(null);
      }
    }

    // /api/tools/<name>
    if (segments.length == 3 && segments[1] == 'tools' && method == 'POST') {
      return _invoke(segments[2], body);
    }

    // /api/player/*
    if (segments.length == 3 && segments[1] == 'player') {
      const simple = {
        'play': 'play',
        'pause': 'pause',
        'toggle': 'toggle',
        'stop': 'stop',
        'next': 'next_track',
        'previous': 'previous_track',
      };
      if (simple.containsKey(segments[2]) && method == 'POST') {
        return _invoke(simple[segments[2]]!, const {});
      }
      switch (segments[2]) {
        case 'seek':
          if (method == 'POST') return _invoke('seek', body);
          return Future.value(null);
        case 'volume':
          if (method == 'PUT' || method == 'POST') {
            return _invoke('set_volume', body);
          }
          return Future.value(null);
        case 'repeat':
          if (method == 'PUT' || method == 'POST') {
            return _invoke('set_repeat_mode', body);
          }
          return Future.value(null);
        case 'shuffle':
          if (method == 'PUT' || method == 'POST') {
            return _invoke('set_shuffle', body);
          }
          return Future.value(null);
        case 'quality':
          if (method == 'PUT' || method == 'POST') {
            return _invoke('set_quality', body);
          }
          return Future.value(null);
        case 'track':
          if (method == 'POST') return _invoke('play_track', body);
          return Future.value(null);
        case 'tracks':
          if (method == 'POST') return _invoke('play_tracks', body);
          return Future.value(null);
      }
    }

    // /api/queue/*
    if (segments.length == 3 && segments[1] == 'queue') {
      switch (segments[2]) {
        case 'play':
          if (method == 'POST') return _invoke('queue_play_index', body);
          return Future.value(null);
        case 'add':
          if (method == 'POST') return _invoke('queue_add', body);
          return Future.value(null);
      }
    }
    if (segments.length == 4 &&
        segments[1] == 'queue' &&
        segments[2] == 'tracks') {
      if (segments[3] == 'move' && (method == 'PUT' || method == 'POST')) {
        return _invoke('queue_move', body);
      }
      if (method == 'DELETE') {
        return _invoke('queue_remove', {'index': _intOrNull(segments[3])});
      }
    }

    // /api/library/*
    if (segments.length == 3 && segments[1] == 'library' && method == 'GET') {
      switch (segments[2]) {
        case 'search':
          return _invoke('library_search', {
            if (q['q'] != null) 'query': q['q'],
            if (q['limit'] != null) 'limit': _intOrNull(q['limit']),
            if (q['offset'] != null) 'offset': _intOrNull(q['offset']),
          });
        case 'random':
          return _invoke('library_random', {
            if (q['limit'] != null) 'limit': _intOrNull(q['limit']),
          });
        case 'stats':
          return _invoke('library_stats', const {});
      }
    }

    return Future.value(null);
  }

  Future<Object?> _invoke(String name, Map<String, dynamic> args) async {
    final cfg = config();
    final tool = tools().where((t) => t.name == name).firstOrNull;
    if (tool == null) {
      throw McpActionException('not_found', '未知工具: $name');
    }
    if (!cfg.has(tool.capability)) {
      throw McpActionException('unsupported', '工具未启用: $name');
    }
    // 去掉 null 值，交由工具的参数解析判定必填项。
    final clean = <String, dynamic>{
      for (final e in args.entries)
        if (e.value != null) e.key: e.value,
    };
    return tool.handle(clean);
  }

  Map<String, Object?> _toolCatalog() => {
    'tools': [
      for (final tool in tools())
        if (config().has(tool.capability))
          {
            'name': tool.name,
            'title': tool.title,
            'description': tool.description,
            'capability': tool.capability.id,
            'inputSchema': tool.inputSchema,
            'annotations': tool.annotations,
          },
    ],
  };

  Map<String, Object?> _info() => {
    ...api.appInfo(),
    'service': {
      'port': config().port,
      'lan': config().allowLan,
      'protocolVersion': kMcpPreferredVersion,
      'endpoints': const {'mcp': '/mcp', 'rest': '/api', 'websocket': '/ws'},
      'capabilities': [
        for (final c in McpCapability.values)
          if (config().has(c)) c.id,
      ],
    },
  };

  Map<String, Object?> _rootPayload() => {
    'name': 'ArchoeraMusic MCP control',
    'version': kMcpPreferredVersion,
    'endpoints': const {
      'mcp': '/mcp',
      'rest': '/api',
      'websocket': '/ws',
      'health': '/api/health',
    },
  };

  // ── 工具方法 ──────────────────────────────────────────────────

  static Map<String, Object?> _error(String code, String message) => {
    'error': {'code': code, 'message': message},
  };

  static int _statusFor(String code) => switch (code) {
    'invalid_argument' => HttpStatus.badRequest,
    'not_found' => HttpStatus.notFound,
    'unsupported' => HttpStatus.forbidden,
    'unavailable' => HttpStatus.serviceUnavailable,
    _ => HttpStatus.internalServerError,
  };

  static int? _intOrNull(String? raw) => raw == null ? null : int.tryParse(raw);

  static Future<String> _readBody(HttpRequest request) async {
    final chunks = <int>[];
    await for (final chunk in request) {
      chunks.addAll(chunk);
      if (chunks.length > 1 << 20) break; // 1 MiB 上限
    }
    return utf8.decode(chunks, allowMalformed: true);
  }

  static Future<void> _json(
    HttpResponse response,
    int status,
    Object? body,
  ) async {
    response.statusCode = status;
    response.headers.contentType = ContentType(
      'application',
      'json',
      charset: 'utf-8',
    );
    response.write(jsonEncode(body));
    await response.close();
  }
}
