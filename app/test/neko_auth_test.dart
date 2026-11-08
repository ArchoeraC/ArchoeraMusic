// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// NekoAuth / 扫码登录的新请求方案单测：
// - `nekomusic://sso/complete?handoff=…` 深链解析与等待；
// - `/api/user/sso/claim`、`/api/user/qrlogin/claim` 换取 token；
// - 退出登录调用 `/api/user/logout` 并清理本地会话。

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/apis/neko/neko_client.dart';
import 'package:archoera_music/apis/runtime.dart';
import 'package:archoera_music/services/neko/neko_api.dart';
import 'package:archoera_music/services/neko/neko_sso_bridge.dart';
import 'package:archoera_music/services/neko/neko_types.dart';

class _MemorySessionStore implements SessionStore {
  final Map<String, Map<String, String>> _data = {};

  @override
  bool get isLocked => false;

  @override
  Map<String, String> get(String platform) => _data[platform] ?? const {};

  @override
  void save(String platform, Map<String, String> cookies) {
    _data[platform] = Map<String, String>.from(cookies);
  }

  @override
  void clear(String platform) => _data.remove(platform);
}

class _FakeNekoClient extends NekoClient {
  _FakeNekoClient() : super(baseUrl: 'http://test');

  final List<({String method, String path, Object? body})> calls = [];
  final Map<String, Map<String, dynamic>> responses = {};
  final List<NekoSseEvent> events = [];

  @override
  Future<Map<String, dynamic>> getJson(
    String path, {
    Map<String, String>? query,
  }) async {
    calls.add((method: 'GET', path: path, body: null));
    return const {'success': false};
  }

  @override
  Future<Map<String, dynamic>> postJson(String path, {Object? body}) async {
    calls.add((method: 'POST', path: path, body: body));
    return responses[path] ?? const {'success': true};
  }

  @override
  Stream<NekoSseEvent> sse(String path) async* {
    for (final event in events) {
      yield event;
    }
  }
}

Map<String, dynamic> _bodyOf(Object? body) =>
    body is Map ? Map<String, dynamic>.from(body) : const {};

void main() {
  late _MemorySessionStore store;
  late _FakeNekoClient client;
  late NekoApi api;
  late ApisRuntime previous;

  setUp(() {
    previous = getRuntime();
    store = _MemorySessionStore();
    setRuntime(runtime: ApisRuntime(sessionStore: store));
    client = _FakeNekoClient();
    api = NekoApi(clientFactory: (_, _) => client);
    NekoSsoBridge.debugReset();
  });

  tearDown(() {
    setRuntime(runtime: previous);
    NekoSsoBridge.debugReset();
  });

  test('深链解析：nekomusic://sso/complete?handoff=…', () async {
    final pending = NekoSsoBridge.waitForHandoff(
      timeout: const Duration(seconds: 1),
    );
    expect(
      NekoSsoBridge.handleUri(
        Uri.parse('nekomusic://sso/complete?handoff=abc123'),
      ),
      isTrue,
    );
    expect(await pending, 'abc123');
  });

  test('深链早到：先缓存，等待时直接消费', () async {
    NekoSsoBridge.handleUri(
      Uri.parse('nekomusic://sso/complete?handoff=early'),
    );
    expect(
      await NekoSsoBridge.waitForHandoff(
        timeout: const Duration(seconds: 1),
      ),
      'early',
    );
  });

  test('取消等待：立即返回 null，且不抢下一次回调', () async {
    final cancel = Completer<void>();
    final waiting = NekoSsoBridge.waitForHandoff(
      timeout: const Duration(minutes: 1),
      cancel: cancel.future,
    );
    cancel.complete();
    expect(await waiting, isNull);

    final next = NekoSsoBridge.waitForHandoff(
      timeout: const Duration(seconds: 1),
    );
    NekoSsoBridge.handleUri(
      Uri.parse('nekomusic://sso/complete?handoff=next'),
    );
    expect(await next, 'next');
  });

  test('ssoClaim：POST handoff 后落盘 token', () async {
    client.responses['/api/user/sso/claim'] = {
      'success': true,
      'data': {
        'token': 'access-1',
        'idToken': 'id-1',
        'user': {'id': 7, 'nickname': '喵', 'email': 'a@b.c'},
      },
    };

    await api.ssoClaim('handoff-1');

    final call = client.calls.lastWhere(
      (c) => c.path == '/api/user/sso/claim',
    );
    expect(call.path, '/api/user/sso/claim');
    expect(_bodyOf(call.body)['handoff'], 'handoff-1');
    expect(api.isLoggedIn, isTrue);
    expect(api.account?.nickname, '喵');
    expect(store.get(kNekoSessionPlatform)['token'], 'access-1');
  });

  test('扫码：confirmed 后用 deliveryKey 调 claim 领取 token', () async {
    client.responses['/api/user/qrlogin/create'] = {
      'success': true,
      'data': {
        'sessionId': 'sid-1',
        'deliveryKey': 'dk-1',
        'qrImage': '',
        'expiresIn': 180,
      },
    };
    client.responses['/api/user/qrlogin/claim'] = {
      'success': true,
      'data': {
        'status': 'confirmed',
        'token': 'qr-token',
        'user': {'id': 9, 'nickname': '扫码用户'},
      },
    };
    client.events.addAll(const [
      NekoSseEvent(event: 'status', data: '{"status":"pending"}'),
      NekoSseEvent(event: 'status', data: '{"status":"confirmed"}'),
    ]);

    final session = await api.qrCreate();
    expect(session.deliveryKey, 'dk-1');

    final states = await api.qrWatch(session).toList();
    expect(states.last.state, NekoQrState.confirmed);
    expect(api.isLoggedIn, isTrue);
    expect(api.account?.nickname, '扫码用户');
    expect(store.get(kNekoSessionPlatform)['token'], 'qr-token');

    final claim = client.calls.lastWhere(
      (c) => c.path == '/api/user/qrlogin/claim',
    );
    final body = _bodyOf(claim.body);
    expect(body['sessionId'], 'sid-1');
    expect(body['deliveryKey'], 'dk-1');
  });

  test('扫码领取失败：抛 NekoApiException，不落盘', () async {
    client.responses['/api/user/qrlogin/claim'] = {
      'success': true,
      'data': {'status': 'expired'},
    };
    client.events.add(
      const NekoSseEvent(event: 'status', data: '{"status":"confirmed"}'),
    );

    final session = NekoQrSession(
      sessionId: 'sid-1',
      deliveryKey: 'dk-1',
    );
    await expectLater(
      api.qrWatch(session).toList(),
      throwsA(isA<NekoApiException>()),
    );
    expect(api.isLoggedIn, isFalse);
    expect(store.get(kNekoSessionPlatform), isEmpty);
  });

  test('logout：调用 /api/user/logout 并清本地会话', () async {
    client.responses['/api/user/sso/claim'] = {
      'success': true,
      'data': {
        'token': 't',
        'user': {'id': 1, 'nickname': 'n'},
      },
    };
    await api.ssoClaim('h');

    await api.logout();

    expect(api.isLoggedIn, isFalse);
    expect(store.get(kNekoSessionPlatform), isEmpty);
    expect(
      client.calls.any((c) => c.path == '/api/user/logout'),
      isTrue,
      reason: '退出时必须吊销服务端 access token',
    );
  });
}
