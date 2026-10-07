// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// MCP 控制 HTTP 层集成测试：真实回环 HttpServer + REST / MCP 往返，
// 覆盖鉴权、Origin 校验、工具调用与会话握手。
import 'dart:convert';
import 'dart:io';

import 'package:archoera_music/services/mcp/mcp_tools.dart';
import 'package:archoera_music/services/mcp/mcp_http.dart';
import 'package:archoera_music/services/mcp/mcp_protocol.dart';
import 'package:archoera_music/services/mcp/mcp_models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _key = 'test-key';

McpTool _echoTool() => McpTool(
  name: 'echo',
  title: 'Echo',
  description: '回显 value',
  capability: McpCapability.read,
  readOnly: true,
  inputSchema: const {'type': 'object'},
  handle: (args) async => {'echo': args['value']},
);

void main() {
  late ProviderContainer container;
  late HttpServer server;
  late HttpClient client;
  late McpHttpHandler handler;
  late McpConfig config;

  setUp(() async {
    container = ProviderContainer();
    final apiProvider = Provider<McpActions>(
      (ref) => McpActions(ref, McpTrackCache()),
    );
    final api = container.read(apiProvider);
    config = const McpConfig(
      enabled: true,
      port: 0,
      accessKey: _key,
      allowKeyless: false,
      allowLan: false,
      capabilities: {McpCapability.read, McpCapability.preferences},
    );
    final mcp = McpRpcHandler(
      tools: () => [_echoTool()],
      config: () => config,
      api: api,
    );
    handler = McpHttpHandler(
      config: () => config,
      tools: () => [_echoTool()],
      api: api,
      mcp: mcp,
      onWebSocketUpgrade: (_) async {},
    );
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(handler.handle);
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await server.close(force: true);
    container.dispose();
  });

  Uri url(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');

  Future<({int status, Map<String, dynamic> body, HttpHeaders headers})> call(
    String method,
    String path, {
    Object? json,
    String? key = _key,
    String? origin,
    Map<String, String> extraHeaders = const {},
  }) async {
    final request = await client.openUrl(method, url(path));
    if (key != null) request.headers.set('X-Archoera-Key', key);
    if (origin != null) request.headers.set('Origin', origin);
    extraHeaders.forEach(request.headers.set);
    if (json != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(json));
    }
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    return (
      status: response.statusCode,
      body: text.isEmpty
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(text) as Map),
      headers: response.headers,
    );
  }

  test('健康检查免鉴权，业务接口需要密钥', () async {
    final health = await call('GET', '/api/health', key: null);
    expect(health.status, 200);
    expect(health.body['status'], 'ok');

    final unauthorized = await call('GET', '/api/info', key: null);
    expect(unauthorized.status, 401);
    expect((unauthorized.body['error'] as Map)['code'], 'unauthorized');

    final authorized = await call('GET', '/api/info');
    expect(authorized.status, 200);
    expect(authorized.body['name'], 'ArchoeraMusic');
    final service = authorized.body['service'] as Map;
    expect(service['lan'], isFalse);
  });

  test('非法 Origin 返回 403', () async {
    final result = await call(
      'GET',
      '/api/info',
      origin: 'http://evil.example.com',
    );
    expect(result.status, 403);
  });

  test('本机 Origin 放行并回显 CORS', () async {
    final result = await call(
      'GET',
      '/api/info',
      origin: 'http://localhost:3000',
    );
    expect(result.status, 200);
    expect(result.headers.value('access-control-allow-origin'), isNotNull);
  });

  test('REST 工具列举与调用', () async {
    final tools = await call('GET', '/api/tools');
    expect(tools.status, 200);
    final names = (tools.body['tools'] as List)
        .map((t) => (t as Map)['name'])
        .toList();
    expect(names, contains('echo'));

    final invoked = await call(
      'POST',
      '/api/tools/echo',
      json: const {'value': 'hi'},
    );
    expect(invoked.status, 200);
    expect(invoked.body['echo'], 'hi');

    final unknown = await call('POST', '/api/tools/nope', json: const {});
    expect(unknown.status, 404);
  });

  test('MCP 握手 + tools/list + tools/call', () async {
    final init = await call(
      'POST',
      '/mcp',
      json: const {
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': {
          'protocolVersion': kMcpPreferredVersion,
          'capabilities': <String, Object?>{},
          'clientInfo': {'name': 't', 'version': '1'},
        },
      },
    );
    expect(init.status, 200);
    final session = init.headers.value('mcp-session-id')!;
    expect(session, isNotEmpty);

    final list = await call(
      'POST',
      '/mcp',
      extraHeaders: {'Mcp-Session-Id': session},
      json: const {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'},
    );
    expect(list.status, 200);
    final listed = ((list.body['result'] as Map)['tools'] as List)
        .map((t) => (t as Map)['name'])
        .toList();
    expect(listed, contains('echo'));

    final called = await call(
      'POST',
      '/mcp',
      extraHeaders: {'Mcp-Session-Id': session},
      json: const {
        'jsonrpc': '2.0',
        'id': 3,
        'method': 'tools/call',
        'params': {
          'name': 'echo',
          'arguments': {'value': 'mcp'},
        },
      },
    );
    expect(called.status, 200);
    final result = (called.body['result'] as Map);
    expect(result['isError'], isFalse);
    expect((result['structuredContent'] as Map)['echo'], 'mcp');

    final get = await call(
      'GET',
      '/mcp',
      extraHeaders: {'Mcp-Session-Id': session},
    );
    expect(get.status, 405);
  });

  test('不支持的 MCP-Protocol-Version 返回 400', () async {
    final result = await call(
      'POST',
      '/mcp',
      extraHeaders: {'MCP-Protocol-Version': '1999-01-01'},
      json: const {'jsonrpc': '2.0', 'id': 1, 'method': 'ping'},
    );
    expect(result.status, 400);
  });
}
