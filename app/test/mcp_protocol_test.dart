// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// MCP 控制协议层单测：配置值语义、恒定时间比较、曲目缓存，以及 MCP
// JSON-RPC 握手 / 会话 / 工具列举与调用（不依赖网络与引擎）。
import 'package:archoera_music/services/mcp/mcp_tools.dart';
import 'package:archoera_music/services/mcp/mcp_protocol.dart';
import 'package:archoera_music/services/mcp/mcp_models.dart';
import 'package:archoera_music/services/netease/track.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

McpTool _echoTool() => McpTool(
  name: 'echo',
  title: 'Echo',
  description: '回显 value',
  capability: McpCapability.read,
  readOnly: true,
  inputSchema: const {'type': 'object'},
  handle: (args) async => {'echo': args['value']},
);

McpTool _boomTool() => McpTool(
  name: 'boom',
  title: 'Boom',
  description: '抛出动作异常',
  capability: McpCapability.playback,
  inputSchema: const {'type': 'object'},
  handle: (args) async =>
      throw const McpActionException('invalid_argument', '坏参数'),
);

/// 读取 JSON-RPC 响应体。
Map<String, dynamic> _body(McpHttpResult result) =>
    Map<String, dynamic>.from(result.body! as Map);

void main() {
  group('McpConfig', () {
    test('按值相等（含能力集合）', () {
      const a = McpConfig(
        enabled: true,
        port: 1234,
        accessKey: 'k',
        allowKeyless: false,
        allowLan: false,
        capabilities: {McpCapability.read, McpCapability.queue},
      );
      const b = McpConfig(
        enabled: true,
        port: 1234,
        accessKey: 'k',
        allowKeyless: false,
        allowLan: false,
        capabilities: {McpCapability.queue, McpCapability.read},
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(
        a ==
            const McpConfig(
              enabled: true,
              port: 1234,
              accessKey: 'k',
              allowKeyless: false,
              allowLan: false,
              capabilities: {McpCapability.read},
            ),
        isFalse,
      );
      // allowLan 参与值语义。
      expect(a == a.copyWith(allowLan: true), isFalse);
      expect(a.copyWith(allowLan: true) == a.copyWith(allowLan: true), isTrue);
    });
  });

  group('constantTimeEquals', () {
    test('相等 / 不等 / 长度差 / null', () {
      expect(constantTimeEquals('abc', 'abc'), isTrue);
      expect(constantTimeEquals('abc', 'abd'), isFalse);
      expect(constantTimeEquals('abc', 'abcd'), isFalse);
      expect(constantTimeEquals('', ''), isTrue);
      expect(constantTimeEquals(null, 'abc'), isFalse);
      expect(constantTimeEquals('abc', null), isFalse);
    });
  });

  group('McpTrackCache', () {
    test('ref 与 LRU 淘汰', () {
      final cache = McpTrackCache(maxEntries: 2);
      const t1 = Track(id: '1', title: 'a', source: 'netease');
      const t2 = Track(id: '2', title: 'b', source: 'kugou');
      const t3 = Track(id: '3', title: 'c', source: 'netease');
      expect(McpTrackCache.refOf(t1), 'netease:1');
      cache
        ..put(t1)
        ..put(t2);
      expect(cache.get('netease:1'), isNotNull); // 刷新 t1 为最近使用
      cache.put(t3); // 淘汰最久未用的 t2
      expect(cache.get('netease:1'), isNotNull);
      expect(cache.get('kugou:2'), isNull);
      expect(cache.get('netease:3'), isNotNull);
    });
  });

  group('McpRpcHandler', () {
    late ProviderContainer container;
    late McpRpcHandler handler;
    late McpConfig config;

    setUp(() {
      container = ProviderContainer();
      addTearDown(container.dispose);
      final apiProvider = Provider<McpActions>(
        (ref) => McpActions(ref, McpTrackCache()),
      );
      final api = container.read(apiProvider);
      config = const McpConfig(
        enabled: true,
        port: 14559,
        accessKey: 'k',
        allowKeyless: false,
        allowLan: false,
        capabilities: {
          McpCapability.read,
          McpCapability.playback,
          McpCapability.queue,
          McpCapability.search,
          McpCapability.library,
          McpCapability.preferences,
        },
      );
      handler = McpRpcHandler(
        tools: () => [_echoTool(), _boomTool()],
        config: () => config,
        api: api,
      );
    });

    Future<String> initialize() async {
      final result = await handler.handleMessage({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': {
          'protocolVersion': kMcpPreferredVersion,
          'capabilities': <String, Object?>{},
          'clientInfo': {'name': 'test', 'version': '1'},
        },
      });
      expect(result.status, 200);
      final sessionId = result.headers['Mcp-Session-Id'];
      expect(sessionId, isNotEmpty);
      final body = _body(result);
      final res = Map<String, dynamic>.from(body['result'] as Map);
      expect(res['protocolVersion'], kMcpPreferredVersion);
      final info = Map<String, dynamic>.from(res['serverInfo'] as Map);
      expect(info['name'], 'archoera-music');
      return sessionId!;
    }

    test('initialize 协商版本并颁发会话', () async {
      final result = await handler.handleMessage({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': {'protocolVersion': '2099-01-01'},
      });
      final res = Map<String, dynamic>.from(_body(result)['result'] as Map);
      // 不支持则回退本端首选版本。
      expect(res['protocolVersion'], kMcpPreferredVersion);
    });

    test('缺少会话的请求返回 400', () async {
      final result = await handler.handleMessage({
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'tools/list',
      });
      expect(result.status, 400);
    });

    test('未知会话返回 404', () async {
      final result = await handler.handleMessage({
        'jsonrpc': '2.0',
        'id': 3,
        'method': 'tools/list',
      }, sessionId: 'nope');
      expect(result.status, 404);
    });

    test('tools/list 只暴露已启用能力组', () async {
      final sessionId = await initialize();
      final result = await handler.handleMessage({
        'jsonrpc': '2.0',
        'id': 4,
        'method': 'tools/list',
      }, sessionId: sessionId);
      final res = Map<String, dynamic>.from(_body(result)['result'] as Map);
      final tools = res['tools'] as List;
      expect(
        tools.map((t) => (t as Map)['name']),
        containsAll(['echo', 'boom']),
      );
    });

    test('能力组关闭后工具不可见', () async {
      config = config.copyWith(capabilities: {McpCapability.playback});
      final sessionId = await initialize();
      final result = await handler.handleMessage({
        'jsonrpc': '2.0',
        'id': 5,
        'method': 'tools/list',
      }, sessionId: sessionId);
      final res = Map<String, dynamic>.from(_body(result)['result'] as Map);
      final names = (res['tools'] as List).map((t) => (t as Map)['name']);
      expect(names, contains('boom'));
      expect(names, isNot(contains('echo')));
    });

    test('tools/call 成功返回结构化内容', () async {
      final sessionId = await initialize();
      final result = await handler.handleMessage({
        'jsonrpc': '2.0',
        'id': 6,
        'method': 'tools/call',
        'params': {
          'name': 'echo',
          'arguments': {'value': 'hi'},
        },
      }, sessionId: sessionId);
      final res = Map<String, dynamic>.from(_body(result)['result'] as Map);
      expect(res['isError'], isFalse);
      expect((res['structuredContent'] as Map)['echo'], 'hi');
    });

    test('动作异常以 isError 返回而非协议错误', () async {
      final sessionId = await initialize();
      final result = await handler.handleMessage({
        'jsonrpc': '2.0',
        'id': 7,
        'method': 'tools/call',
        'params': {'name': 'boom', 'arguments': <String, Object?>{}},
      }, sessionId: sessionId);
      final res = Map<String, dynamic>.from(_body(result)['result'] as Map);
      expect(res['isError'], isTrue);
    });

    test('调用未启用 / 未知工具返回 -32602', () async {
      config = config.copyWith(capabilities: {McpCapability.queue});
      final sessionId = await initialize();
      final result = await handler.handleMessage({
        'jsonrpc': '2.0',
        'id': 8,
        'method': 'tools/call',
        'params': {'name': 'echo', 'arguments': <String, Object?>{}},
      }, sessionId: sessionId);
      final error = _body(result)['error'] as Map;
      expect(error['code'], -32602);
    });

    test('未实现方法返回 -32601', () async {
      final sessionId = await initialize();
      final result = await handler.handleMessage({
        'jsonrpc': '2.0',
        'id': 9,
        'method': 'does/not/exist',
      }, sessionId: sessionId);
      final error = _body(result)['error'] as Map;
      expect(error['code'], -32601);
    });

    test('通知返回 202，GET 返回 405，DELETE 关闭会话', () async {
      final sessionId = await initialize();
      final notification = await handler.handleMessage({
        'jsonrpc': '2.0',
        'method': 'notifications/initialized',
      }, sessionId: sessionId);
      expect(notification.status, 202);
      expect(handler.getStreamResult().status, 405);
      expect(handler.deleteSession(sessionId).status, 204);
      final after = await handler.handleMessage({
        'jsonrpc': '2.0',
        'id': 10,
        'method': 'tools/list',
      }, sessionId: sessionId);
      expect(after.status, 404);
    });
  });

  group('工具目录', () {
    test('名称唯一且每个能力组都有工具', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final apiProvider = Provider<McpActions>(
        (ref) => McpActions(ref, McpTrackCache()),
      );
      final tools = buildMcpTools(container.read(apiProvider));
      final names = tools.map((t) => t.name).toList();
      expect(names.toSet().length, names.length, reason: '工具名必须唯一');
      for (final capability in McpCapability.values) {
        expect(
          tools.any((t) => t.capability == capability),
          isTrue,
          reason: '能力组 ${capability.id} 无对应工具',
        );
      }
    });
  });

  group('曲目引用解析', () {
    test('未缓存 ref 拆分为 source:id', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final api = container.read(
        Provider<McpActions>((ref) => McpActions(ref, McpTrackCache())),
      );
      final track = api.resolveTrack(const {'ref': 'netease:42'});
      expect(track.source, 'netease');
      expect(track.id, '42');
    });

    test('source+id 直接用；缺参报错', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final api = container.read(
        Provider<McpActions>((ref) => McpActions(ref, McpTrackCache())),
      );
      final track = api.resolveTrack(const {'source': 'kugou', 'id': 'abc'});
      expect(track.source, 'kugou');
      expect(track.id, 'abc');
      expect(
        () => api.resolveTrack(const {}),
        throwsA(isA<McpActionException>()),
      );
    });
  });
}
