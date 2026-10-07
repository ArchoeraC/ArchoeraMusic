// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// MCP（Model Context Protocol）服务端：Streamable HTTP 传输 + JSON-RPC 2.0。
///
/// 仅实现协议中与「MCP 操作本应用」相关的部分：`initialize` 握手与会话、
/// `tools/list` / `tools/call`、`resources/list` / `resources/read`、`ping`
/// 及通知。响应使用 `application/json`（不启用 SSE），符合规范中「服务器
/// 可只返回单个 JSON 对象」的约定；GET 返回 405 表示不提供 SSE 流。
///
/// 协议版本按 2025-11-25 协商：回显客户端支持的版本，否则回退到本端首选
/// 版本（客户端可据此断开或重试）。
library;

import 'dart:convert';
import 'dart:math';

import '../../utils/app_version.dart';
import 'mcp_tools.dart';
import 'mcp_models.dart';

/// 本端首选协议版本（握手协商回退值）。
const String kMcpPreferredVersion = '2025-11-25';

/// 本端支持的协议版本（握手期回显客户端请求）。
const List<String> kMcpSupportedVersions = [
  '2025-11-25',
  '2025-06-18',
  '2025-03-26',
  '2024-11-05',
];

/// 一个 HTTP 处理结果（状态码 + 头 + JSON 体）。
class McpHttpResult {
  const McpHttpResult({
    required this.status,
    this.headers = const {},
    this.body,
  });

  final int status;
  final Map<String, String> headers;
  final Object? body;
}

class _McpSession {
  _McpSession(this.id, this.protocolVersion);

  final String id;
  final String protocolVersion;
  DateTime lastUsed = DateTime.now();
}

/// MCP 协议处理器（每请求从服务读取最新配置与工具目录）。
class McpRpcHandler {
  McpRpcHandler({required this.tools, required this.config, required this.api});

  /// 全部工具（含未启用的；本类按配置过滤）。
  final List<McpTool> Function() tools;
  final McpConfig Function() config;
  final McpActions api;

  static const int _maxSessions = 8;
  static const Duration _sessionIdle = Duration(minutes: 30);

  final Map<String, _McpSession> _sessions = {};
  final Random _rng = Random.secure();

  int get sessionCount => _sessions.length;

  /// 释放全部会话（服务重启时调用）。
  void reset() => _sessions.clear();

  /// 处理一次 POST 到 `/mcp` 的 JSON-RPC 消息。
  Future<McpHttpResult> handleMessage(
    Object? decoded, {
    String? sessionId,
  }) async {
    if (decoded is! Map) {
      return _rpcError(400, null, -32600, 'Invalid Request');
    }
    final message = Map<String, dynamic>.from(decoded);
    final id = message['id'];
    final isNotification = !message.containsKey('id');
    final method = message['method'];
    if (method is! String) {
      // JSON-RPC 响应（result/error）与通知一律接受；其余视为非法请求。
      if (isNotification ||
          message.containsKey('result') ||
          message.containsKey('error')) {
        return const McpHttpResult(status: 202);
      }
      return _rpcError(200, id, -32600, 'Invalid Request');
    }

    if (method == 'initialize') {
      if (isNotification) return const McpHttpResult(status: 202);
      if (message['params'] is! Map) {
        return _rpcError(200, id, -32602, 'initialize 缺少 params');
      }
      return _initialize(
        id,
        Map<String, dynamic>.from(message['params'] as Map),
      );
    }

    // 除 initialize 外均要求有效会话。
    if (sessionId == null || sessionId.isEmpty) {
      return _rpcError(400, id, -32000, '缺少 Mcp-Session-Id');
    }
    final session = _sessions[sessionId];
    if (session == null) {
      return _rpcError(404, id, -32001, '会话不存在或已过期');
    }
    session.lastUsed = DateTime.now();

    if (isNotification) {
      // 通知（initialized / cancelled / progress 等）一律接受。
      return const McpHttpResult(status: 202);
    }

    final params = message['params'] is Map
        ? Map<String, dynamic>.from(message['params'] as Map)
        : <String, dynamic>{};
    try {
      switch (method) {
        case 'ping':
          return _rpcResult(id, const {});
        case 'tools/list':
          return _rpcResult(id, {'tools': _toolDescriptors()});
        case 'tools/call':
          return await _callTool(id, params);
        case 'resources/list':
          return _rpcResult(id, {'resources': _resources()});
        case 'resources/read':
          return await _readResource(id, params);
        case 'resources/templates/list':
          return _rpcResult(id, const {'resourceTemplates': []});
        case 'prompts/list':
          return _rpcResult(id, const {'prompts': []});
        case 'logging/setLevel':
          return _rpcResult(id, const {});
        default:
          return _rpcError(200, id, -32601, '未实现的方法: $method');
      }
    } catch (e) {
      return _rpcError(200, id, -32603, '内部错误: $e');
    }
  }

  /// GET `/mcp`：本端不提供 SSE，按规范返回 405。
  McpHttpResult getStreamResult() =>
      _rpcError(405, null, -32000, '本服务不提供 SSE 流；请使用 POST 发送 JSON-RPC 消息');

  /// DELETE `/mcp`：显式关闭会话。
  McpHttpResult deleteSession(String? sessionId) {
    if (sessionId != null) _sessions.remove(sessionId);
    return const McpHttpResult(status: 204);
  }

  McpHttpResult _initialize(Object? id, Map<String, dynamic> params) {
    final requested = params['protocolVersion'];
    final negotiated =
        (requested is String && kMcpSupportedVersions.contains(requested))
        ? requested
        : kMcpPreferredVersion;
    final sessionId = _newSessionId();
    _sessions[sessionId] = _McpSession(sessionId, negotiated);
    _evictSessions();
    return McpHttpResult(
      status: 200,
      headers: {'Mcp-Session-Id': sessionId},
      body: {
        'jsonrpc': '2.0',
        'id': id,
        'result': {
          'protocolVersion': negotiated,
          'capabilities': {
            'tools': const {'listChanged': false},
            'resources': const {'subscribe': false, 'listChanged': false},
          },
          'serverInfo': {
            'name': 'archoera-music',
            'title': 'ArchoeraMusic',
            'version': appVersion,
          },
          'instructions':
              'ArchoeraMusic 本地控制服务：可查询播放状态、控制播放/队列、'
              '搜索在线音源与本地曲库、读取应用偏好。',
        },
      },
    );
  }

  List<McpTool> get _enabledTools {
    final cfg = config();
    return tools().where((t) => cfg.has(t.capability)).toList(growable: false);
  }

  List<Map<String, Object?>> _toolDescriptors() => [
    for (final tool in _enabledTools)
      {
        'name': tool.name,
        'title': tool.title,
        'description': tool.description,
        'inputSchema': tool.inputSchema,
        'annotations': tool.annotations,
      },
  ];

  Future<McpHttpResult> _callTool(
    Object? id,
    Map<String, dynamic> params,
  ) async {
    final name = params['name'];
    if (name is! String || name.isEmpty) {
      return _rpcError(200, id, -32602, 'tools/call 缺少 name');
    }
    final tool = _enabledTools.where((t) => t.name == name).firstOrNull;
    if (tool == null) {
      return _rpcError(200, id, -32602, '未知或未启用的工具: $name');
    }
    final rawArgs = params['arguments'];
    final args = rawArgs is Map
        ? Map<String, dynamic>.from(rawArgs)
        : <String, dynamic>{};
    try {
      final result = await tool.handle(args);
      return _rpcResult(id, {
        'content': [
          {'type': 'text', 'text': jsonEncode(result)},
        ],
        if (result is Map) 'structuredContent': result,
        'isError': false,
      });
    } on McpActionException catch (e) {
      return _toolError(id, '${e.code}: ${e.message}');
    } catch (e) {
      return _toolError(id, '$e');
    }
  }

  McpHttpResult _toolError(Object? id, String message) => _rpcResult(id, {
    'content': [
      {'type': 'text', 'text': 'error: $message'},
    ],
    'isError': true,
  });

  List<Map<String, Object?>> _resources() {
    if (!config().has(McpCapability.read)) return const [];
    return const [
      {
        'uri': 'archoera://now-playing',
        'name': 'now-playing',
        'title': '当前播放',
        'description': '当前曲目与播放进度',
        'mimeType': 'application/json',
      },
      {
        'uri': 'archoera://queue',
        'name': 'queue',
        'title': '播放队列',
        'description': '当前播放队列与模式',
        'mimeType': 'application/json',
      },
      {
        'uri': 'archoera://library/summary',
        'name': 'library-summary',
        'title': '本地曲库统计',
        'description': '曲目数、总大小与总时长',
        'mimeType': 'application/json',
      },
    ];
  }

  Future<McpHttpResult> _readResource(
    Object? id,
    Map<String, dynamic> params,
  ) async {
    final uri = params['uri'];
    if (uri is! String) {
      return _rpcError(200, id, -32602, 'resources/read 缺少 uri');
    }
    dynamic payload;
    switch (uri) {
      case 'archoera://now-playing':
        payload = api.nowPlaying();
      case 'archoera://queue':
        payload = api.queueStatus();
      case 'archoera://library/summary':
        payload = api.libraryStats();
      default:
        return _rpcResult(id, {
          'contents': [
            {
              'uri': uri,
              'mimeType': 'text/plain',
              'text': 'error: not_found 未知资源 $uri',
            },
          ],
        });
    }
    return _rpcResult(id, {
      'contents': [
        {
          'uri': uri,
          'mimeType': 'application/json',
          'text': jsonEncode(payload),
        },
      ],
    });
  }

  McpHttpResult _rpcResult(Object? id, Object? result) => McpHttpResult(
    status: 200,
    headers: const {'Content-Type': 'application/json'},
    body: {'jsonrpc': '2.0', 'id': id, 'result': result},
  );

  McpHttpResult _rpcError(int status, Object? id, int code, String message) =>
      McpHttpResult(
        status: status,
        headers: const {'Content-Type': 'application/json'},
        body: {
          'jsonrpc': '2.0',
          'id': id,
          'error': {'code': code, 'message': message},
        },
      );

  String _newSessionId() {
    final bytes = List<int>.generate(16, (_) => _rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  void _evictSessions() {
    final now = DateTime.now();
    _sessions.removeWhere(
      (_, session) => now.difference(session.lastUsed) > _sessionIdle,
    );
    while (_sessions.length > _maxSessions) {
      final oldest = _sessions.values.reduce(
        (a, b) => a.lastUsed.isBefore(b.lastUsed) ? a : b,
      );
      _sessions.remove(oldest.id);
    }
  }
}
