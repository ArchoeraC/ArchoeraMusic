// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// Neko 账号密码登录单测（本地假服务端，不访问外网）：
// - `NekoAuthClient` 复刻官方 PC 的 SSO 链路（start → login → authorize →
//   callback 302 → claim），校验请求顺序、状态码 / Set-Cookie / handoff 解析；
// - `NekoApi` 的会话落盘、静默续期、401 兜底与「切换登录方式清刷新令牌」。
//
// 协议依据见 `docs/neko-source-identity.md`。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/apis/neko/neko_auth_client.dart';
import 'package:archoera_music/apis/neko/neko_client.dart';
import 'package:archoera_music/apis/runtime.dart';
import 'package:archoera_music/services/neko/neko_api.dart';
import 'package:archoera_music/services/neko/neko_types.dart';

// ── 测试夹具 ─────────────────────────────────────────────────────

String _seg(Object value) =>
    base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');

/// 造一个只用于解析 `exp` 的假 JWT（不验签）。
String fakeJwt({required DateTime expiresAt, String sub = '3361'}) {
  final header = _seg({'alg': 'RS256', 'typ': 'JWT'});
  final payload = _seg({
    'iss': 'https://auth.example',
    'sub': sub,
    'client_id': 'fn_test',
    'exp': expiresAt.millisecondsSinceEpoch ~/ 1000,
  });
  return '$header.$payload.sig';
}

/// 本地假服务端：同时扮演 NekoMusic 与 NekoAuth。
class _MockServer {
  _MockServer._(this._server);

  final HttpServer _server;
  final List<String> hits = [];
  final List<String?> origins = [];

  /// 让 `/api/oauth/authorize` 返回 `redirectUrl: null`（模拟第一方自动同意失效）。
  bool requireConsent = false;
  bool refreshRejected = false;

  String get base => 'http://127.0.0.1:${_server.port}';

  static Future<_MockServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final mock = _MockServer._(server);
    server.listen(mock._handle);
    return mock;
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    hits.add('${req.method} $path');
    origins.add(req.headers.value('origin'));
    switch (path) {
      case '/api/user/sso/start':
        return _json(req, {
          'success': true,
          'data': {
            'url':
                '$base/oauth2/authorize'
                '?client_id=fn_test'
                '&redirect_uri=${Uri.encodeComponent('$base/oauth/nekocore/callback')}'
                '&response_type=code'
                '&scope=openid+profile+email+roles'
                '&state=st-1'
                '&nonce=n-1'
                '&code_challenge=cc-1'
                '&code_challenge_method=S256',
          },
        });
      case '/api/auth/login':
        final body = jsonDecode(await utf8.decoder.bind(req).join());
        if (body is! Map || body['password'] != 'good-password') {
          return _json(req, {
            'status': 401,
            'code': 'INVALID_CREDENTIALS',
            'message': '账号或密码错误',
          }, status: 401);
        }
        req.response.headers.add(
          HttpHeaders.setCookieHeader,
          'refresh_token=rt-1; Path=/; HttpOnly',
        );
        // 真实服务端还会下发一个同名空 Cookie 用于清理旧路径；解析必须忽略它。
        req.response.headers.add(
          HttpHeaders.setCookieHeader,
          'refresh_token=; Path=/api/auth; Max-Age=0',
        );
        return _json(req, {
          'accessToken': 'auth-at-1',
          'tokenType': 'Bearer',
          'expiresIn': 899,
          'user': {'id': '3361', 'username': 'tester', 'nickname': 'Tester'},
        });
      case '/api/oauth/authorize':
        if (req.headers.value(HttpHeaders.authorizationHeader) !=
            'Bearer auth-at-1') {
          return _json(req, {'code': 'LOGIN_REQUIRED'}, status: 401);
        }
        if (req.uri.queryParameters['state'] != 'st-1') {
          return _json(req, {'message': 'state 丢失'}, status: 400);
        }
        return _json(req, {
          'clientId': 'fn_test',
          'clientName': 'NekoMusic',
          'scopes': ['openid', 'profile', 'email', 'roles'],
          'previouslyApproved': !requireConsent,
          'redirectUrl': requireConsent
              ? null
              : '$base/oauth/nekocore/callback?code=code-1&state=st-1',
        });
      case '/api/oauth/authorize/decision':
        return _json(req, {
          'redirectUrl': '$base/oauth/nekocore/callback?code=code-1&state=st-1',
        });
      case '/oauth/nekocore/callback':
        if (req.uri.queryParameters['code'] != 'code-1') {
          return _json(req, {
            'success': false,
            'error': 'authorization_failed',
            'message': '缺少授权码',
          }, status: 400);
        }
        req.response.statusCode = HttpStatus.found;
        req.response.headers.set(
          HttpHeaders.locationHeader,
          '/sso/native-complete?client=pc&handoff=ho-1',
        );
        await req.response.close();
        return;
      case '/api/user/sso/claim':
        final body = jsonDecode(await utf8.decoder.bind(req).join());
        if (body is! Map || body['handoff'] != 'ho-1') {
          return _json(req, {'success': false, 'message': '登录交接已过期'});
        }
        return _json(req, {
          'success': true,
          'message': '登录成功',
          'data': {
            'token': fakeJwt(
              expiresAt: DateTime.now().add(const Duration(days: 364)),
            ),
            'idToken': 'id-token',
            'user': {
              'id': 3361,
              'nickname': 'Tester',
              'email': 'tester@example.com',
              'isVip': false,
            },
          },
        });
      case '/api/auth/logout':
        if (req.headers.value(HttpHeaders.cookieHeader) !=
            'refresh_token=rt-2') {
          return _json(req, {'message': '缺少刷新令牌'}, status: 401);
        }
        req.response.statusCode = HttpStatus.noContent;
        await req.response.close();
        return;
      case '/api/auth/refresh':
        if (refreshRejected) {
          return _json(req, {
            'status': 401,
            'code': 'REFRESH_EXPIRED',
            'message': '登录状态已过期，请重新登录',
          }, status: 401);
        }
        if (req.headers.value(HttpHeaders.cookieHeader) !=
            'refresh_token=rt-1') {
          return _json(req, {'message': '缺少刷新令牌'}, status: 401);
        }
        req.response.headers.add(
          HttpHeaders.setCookieHeader,
          'refresh_token=rt-2; Path=/; HttpOnly',
        );
        return _json(req, {
          'accessToken': 'auth-at-1',
          'tokenType': 'Bearer',
          'expiresIn': 899,
        });
      default:
        return _json(req, {'message': 'not found'}, status: 404);
    }
  }

  Future<void> _json(
    HttpRequest req,
    Object body, {
    int status = 200,
  }) async {
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(body));
    await req.response.close();
  }
}

/// 内存会话存储（vault 替身）。
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

/// 可编排的 NekoClient 替身：默认成功，按需抛 401 / 触发 onUnauthorized。
class _FakeNekoClient extends NekoClient {
  _FakeNekoClient() : super(baseUrl: 'http://test');

  final List<String> calls = [];
  bool infoAuthorized = true;

  @override
  Future<Map<String, dynamic>> getJson(
    String path, {
    Map<String, String>? query,
  }) async {
    calls.add('GET $path');
    if (path == '/api/user/info') {
      if (!infoAuthorized) {
        onUnauthorized?.call('HTTP 401');
        throw NekoApiException('HTTP 401', statusCode: 401, kind: NekoErrorKind.auth);
      }
      return const {
        'success': true,
        'data': {
          'user': {'id': 3361, 'nickname': 'Tester'},
        },
      };
    }
    return const {'success': true};
  }

  @override
  Future<Map<String, dynamic>> postJson(String path, {Object? body}) async {
    calls.add('POST $path');
    return const {'success': true};
  }
}

/// 可编排的 NekoAuthService 替身。
class _FakeAuthService implements NekoAuthService {
  NekoAuthSession? signInSession;
  NekoAuthSession? refreshSession;
  Object? refreshError;

  final List<String> log = [];
  int refreshCalls = 0;
  int revokeCalls = 0;
  String? revokedToken;
  String? revokedBase;
  Object? revokeError;

  @override
  Future<NekoAuthSession> signIn({
    required String identifier,
    required String password,
  }) async {
    log.add('signIn $identifier');
    final session = signInSession;
    if (session == null) {
      throw NekoApiException('账号或密码错误');
    }
    return session;
  }

  @override
  Future<NekoAuthSession> refresh(String authRefreshToken) async {
    refreshCalls++;
    log.add('refresh $authRefreshToken');
    final error = refreshError;
    if (error != null) throw error;
    final session = refreshSession;
    if (session == null) {
      throw NekoApiException('登录态已失效', kind: NekoErrorKind.auth);
    }
    return session;
  }

  @override
  Future<void> revokeSession(String authRefreshToken, {String? authBaseUrl}) async {
    revokeCalls++;
    revokedToken = authRefreshToken;
    revokedBase = authBaseUrl;
    log.add('revokeSession $authRefreshToken');
    final error = revokeError;
    if (error != null) throw error;
  }
}

Future<void> _pump([int turns = 12]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('NekoAuthClient（本地假服务端）', () {
    late _MockServer server;
    late NekoAuthClient client;

    setUp(() async {
      server = await _MockServer.start();
      client = NekoAuthClient(musicBaseUrl: server.base);
    });

    tearDown(() => server.close());

    test('账号密码 → 授权码 → 回调 handoff → claim 全链路', () async {
      final session = await client.signIn(
        identifier: ' tester@example.com ',
        password: 'good-password',
      );

      expect(
        server.hits,
        [
          'POST /api/user/sso/start',
          'POST /api/auth/login',
          'GET /api/oauth/authorize',
          'GET /oauth/nekocore/callback',
          'POST /api/user/sso/claim',
        ],
        reason: '必须严格复刻官方 PC 的 SSO 顺序',
      );
      expect(session.token.split('.').length, 3);
      expect(session.authRefreshToken, 'rt-1');
      expect(session.user?.nickname, 'Tester');
      expect(
        session.expiresAt!.difference(DateTime.now()).inDays,
        greaterThan(300),
        reason: 'access token 约一年有效',
      );
      expect(client.authBaseUrl, server.base);
    });

    test('账号密码错误：保留服务端文案，不产生会话', () async {
      await expectLater(
        client.signIn(identifier: 'tester', password: 'bad'),
        throwsA(
          isA<NekoApiException>()
              .having((e) => e.message, 'message', '账号或密码错误')
              .having((e) => e.kind, 'kind', NekoErrorKind.api),
        ),
      );
      expect(
        server.hits,
        ['POST /api/user/sso/start', 'POST /api/auth/login'],
        reason: '登录失败后不应继续授权',
      );
    });

    test('第一方自动同意不可用：退回 decision 显式同意', () async {
      server.requireConsent = true;

      final session = await client.signIn(
        identifier: 'tester',
        password: 'good-password',
      );

      expect(session.authRefreshToken, 'rt-1');
      expect(server.hits, contains('POST /api/oauth/authorize/decision'));
      expect(server.hits.last, 'POST /api/user/sso/claim');
    });

    test('回调返回 JSON 错误（没有 Location）时抛服务端文案', () async {
      final broken = _MockServer._(
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      );
      // 手工起一个只会把回调打成 400 的服务端。
      broken._server.listen((req) async {
        if (req.uri.path == '/api/user/sso/start') {
          return broken._json(req, {
            'success': true,
            'data': {
              'url':
                  '${broken.base}/oauth2/authorize?client_id=fn_test'
                  '&redirect_uri=${Uri.encodeComponent('${broken.base}/cb')}'
                  '&response_type=code&scope=openid&state=s&nonce=n'
                  '&code_challenge=c&code_challenge_method=S256',
            },
          });
        }
        if (req.uri.path == '/api/auth/login') {
          return broken._json(req, {'accessToken': 'at'});
        }
        if (req.uri.path == '/api/oauth/authorize') {
          return broken._json(req, {'redirectUrl': '${broken.base}/cb?code=x'});
        }
        return broken._json(req, {
          'success': false,
          'message': '授权回调失败',
        }, status: 400);
      });

      final c = NekoAuthClient(musicBaseUrl: broken.base);
      await expectLater(
        c.signIn(identifier: 'a', password: 'b'),
        throwsA(
          isA<NekoApiException>()
              .having((e) => e.message, 'message', '授权回调失败'),
        ),
      );
      await broken.close();
    });

    test('静默续期：带 Cookie、使用 prompt=none、刷新令牌轮换', () async {
      final session = await client.refresh('rt-1');

      expect(server.hits.first, 'POST /api/user/sso/start');
      expect(session.token.split('.').length, 3);
      expect(session.authRefreshToken, 'rt-2', reason: '刷新令牌必须轮换');
    });

    test('注销会话：带 Cookie 调 /api/auth/logout，成功后本地凭据失效', () async {
      final session = await client.refresh('rt-1');
      expect(session.authRefreshToken, 'rt-2');

      await client.revokeSession(
        session.authRefreshToken,
        authBaseUrl: session.authBaseUrl,
      );

      expect(
        server.hits.where((h) => h == 'POST /api/auth/logout').length,
        1,
      );
    });

    test('注销会话：地址未知时明确报错（不静默跳过）', () async {
      await expectLater(
        NekoAuthClient().revokeSession('rt-1'),
        throwsA(isA<NekoApiException>()),
      );
    });

    test('刷新令牌失效：抛 auth 类别（调用方据此清会话）', () async {
      server.refreshRejected = true;

      await expectLater(
        client.refresh('rt-1'),
        throwsA(
          isA<NekoApiException>()
              .having((e) => e.kind, 'kind', NekoErrorKind.auth)
              .having((e) => e.statusCode, 'statusCode', 401),
        ),
      );
    });
  });

  group('NekoApi 会话管理', () {
    late _MemorySessionStore store;
    late _FakeNekoClient nekoClient;
    late _FakeAuthService auth;
    late NekoApi api;
    late ApisRuntime previous;

    setUp(() {
      previous = getRuntime();
      store = _MemorySessionStore();
      setRuntime(runtime: ApisRuntime(sessionStore: store));
      nekoClient = _FakeNekoClient();
      auth = _FakeAuthService();
      api = NekoApi(
        clientFactory: (_, _) => nekoClient,
        authFactory: () => auth,
        passwordLoginEnabled: () => true,
      );
    });

    tearDown(() => setRuntime(runtime: previous));

    NekoAuthSession sessionOf({
      String token = 'token-1',
      String refreshToken = 'rt-1',
      Duration expiresIn = const Duration(days: 300),
    }) => NekoAuthSession(
      token: token,
      authRefreshToken: refreshToken,
      user: const NekoUser(id: '3361', nickname: 'Tester'),
      expiresAt: DateTime.now().add(expiresIn),
      authBaseUrl: 'https://auth.example',
    );

    test('未开启应用内账号密码登录：直接拒绝，不发请求', () async {
      final disabled = NekoApi(
        clientFactory: (_, _) => nekoClient,
        authFactory: () => auth,
      );
      await expectLater(
        disabled.loginWithPassword(identifier: 'tester', password: 'pw'),
        throwsA(
          isA<NekoApiException>().having(
            (e) => e.message,
            'message',
            contains('未启用应用内账号密码登录'),
          ),
        ),
      );
      expect(auth.log, isEmpty);
    });

    test('账号密码登录：token / 刷新令牌 / 过期时间全部落盘', () async {
      auth.signInSession = sessionOf();

      await api.loginWithPassword(
        identifier: ' tester ',
        password: 'good-password',
      );

      expect(auth.log, ['signIn tester']);
      expect(api.isLoggedIn, isTrue);
      final saved = store.get(kNekoSessionPlatform);
      expect(saved['token'], 'token-1');
      expect(saved['authRefreshToken'], 'rt-1');
      expect(saved['userId'], '3361');
      expect(DateTime.tryParse(saved['tokenExpiresAt'] ?? ''), isNotNull);
    });

    test('登录失败：不清已有会话', () async {
      auth.signInSession = sessionOf();
      await api.loginWithPassword(identifier: 'tester', password: 'pw');

      auth.signInSession = null;
      await expectLater(
        api.loginWithPassword(identifier: 'tester', password: 'bad'),
        throwsA(isA<NekoApiException>()),
      );
      expect(api.isLoggedIn, isTrue);
      expect(store.get(kNekoSessionPlatform)['token'], 'token-1');
    });

    test('启动恢复：令牌临近过期时静默续期', () async {
      final expired = sessionOf(expiresIn: const Duration(hours: 2));
      store.save(kNekoSessionPlatform, {
        'token': expired.token,
        'baseUrl': api.baseUrl,
        'authRefreshToken': 'rt-1',
        'authRefreshedAt': DateTime.now().toIso8601String(),
        'tokenExpiresAt': expired.expiresAt!.toIso8601String(),
        'userId': '3361',
        'nickname': 'Tester',
      });
      auth.refreshSession = sessionOf(token: 'token-2', refreshToken: 'rt-2');

      await api.restore();
      await _pump();

      expect(auth.refreshCalls, 1);
      expect(store.get(kNekoSessionPlatform)['token'], 'token-2');
      expect(store.get(kNekoSessionPlatform)['authRefreshToken'], 'rt-2');
    });

    test('启动恢复：距上次续期超过 7 天时保活会话族', () async {
      store.save(kNekoSessionPlatform, {
        'token': 'token-1',
        'baseUrl': api.baseUrl,
        'authRefreshToken': 'rt-1',
        'authRefreshedAt': DateTime.now()
            .subtract(const Duration(days: 8))
            .toIso8601String(),
        'tokenExpiresAt': DateTime.now()
            .add(const Duration(days: 300))
            .toIso8601String(),
        'userId': '3361',
      });
      auth.refreshSession = sessionOf(token: 'token-2', refreshToken: 'rt-2');

      await api.restore();
      await _pump();

      expect(auth.refreshCalls, 1);
      expect(store.get(kNekoSessionPlatform)['token'], 'token-2');
    });

    test('启动恢复：没有刷新令牌 / 令牌仍新时不做请求', () async {
      store.save(kNekoSessionPlatform, {
        'token': 'token-1',
        'baseUrl': api.baseUrl,
        'tokenExpiresAt': DateTime.now()
            .add(const Duration(days: 300))
            .toIso8601String(),
        'userId': '3361',
      });

      await api.restore();
      await _pump();

      expect(auth.refreshCalls, 0);
      expect(api.isLoggedIn, isTrue);
    });

    test('401：先复核再静默续期，续期成功保留登录态', () async {
      auth.signInSession = sessionOf();
      await api.loginWithPassword(identifier: 'tester', password: 'pw');
      auth.refreshSession = sessionOf(token: 'token-2', refreshToken: 'rt-2');
      nekoClient.infoAuthorized = false;

      await api.refreshAccount();
      await _pump();

      expect(auth.refreshCalls, 1);
      expect(store.get(kNekoSessionPlatform)['token'], 'token-2');
      expect(api.isLoggedIn, isTrue);
    });

    test('401 + 刷新令牌失效：清本地会话，要求重新登录', () async {
      auth.signInSession = sessionOf();
      await api.loginWithPassword(identifier: 'tester', password: 'pw');
      auth.refreshError = NekoApiException(
        '登录态已失效',
        statusCode: 401,
        kind: NekoErrorKind.auth,
      );
      nekoClient.infoAuthorized = false;

      await api.refreshAccount();
      await _pump();

      expect(store.get(kNekoSessionPlatform), isEmpty);
      expect(api.isLoggedIn, isFalse);
    });

    test('扫码登录会清掉账号密码登录保存的刷新令牌', () async {
      auth.signInSession = sessionOf();
      await api.loginWithPassword(identifier: 'tester', password: 'pw');
      expect(store.get(kNekoSessionPlatform)['authRefreshToken'], 'rt-1');

      // 扫码领取走 fake NekoClient 的 claim 响应。
      nekoClient.calls.clear();
      final qrClient = _QrNekoClient();
      final qrApi = NekoApi(
        clientFactory: (_, _) => qrClient,
        authFactory: () => auth,
      );
      await qrApi.restore();
      await qrApi
          .qrWatch(NekoQrSession(sessionId: 's', deliveryKey: 'd'))
          .toList();

      expect(qrApi.isLoggedIn, isTrue);
      expect(
        store.get(kNekoSessionPlatform)['authRefreshToken'],
        anyOf(isNull, isEmpty),
        reason: '扫码登录后不应保留另一套账号的 Auth 会话',
      );
    });

    test('退出登录：吊销 token + 注销 Auth 会话族 + 清空本地凭据', () async {
      auth.signInSession = sessionOf(token: 'token-1');
      await api.loginWithPassword(identifier: 'tester', password: 'pw');

      await api.logout();

      expect(api.isLoggedIn, isFalse);
      expect(store.get(kNekoSessionPlatform), isEmpty);
      expect(nekoClient.calls, contains('POST /api/user/logout'));
      expect(auth.revokeCalls, 1, reason: '密码登录的会话族必须服务端注销');
      expect(auth.revokedToken, 'rt-1');
      expect(auth.revokedBase, 'https://auth.example');
    });

    test('退出登录：会话族注销失败也不影响本地退出', () async {
      auth.signInSession = sessionOf(token: 'token-1');
      await api.loginWithPassword(identifier: 'tester', password: 'pw');
      auth.revokeError = NekoApiException('网络不可达', kind: NekoErrorKind.network);

      await api.logout();

      expect(api.isLoggedIn, isFalse);
      expect(store.get(kNekoSessionPlatform), isEmpty);
    });

    test('退出登录：扫码登录没有会话族可注销', () async {
      final qrApi = NekoApi(
        clientFactory: (_, _) => _QrNekoClient(),
        authFactory: () => auth,
        passwordLoginEnabled: () => true,
      );
      await qrApi.restore();
      await qrApi
          .qrWatch(NekoQrSession(sessionId: 's', deliveryKey: 'd'))
          .toList();

      await qrApi.logout();

      expect(qrApi.isLoggedIn, isFalse);
      expect(auth.revokeCalls, 0);
    });
  });
}

/// 专门用于扫码领取的 NekoClient 替身。
class _QrNekoClient extends NekoClient {
  _QrNekoClient() : super(baseUrl: 'http://test');

  @override
  Future<Map<String, dynamic>> getJson(
    String path, {
    Map<String, String>? query,
  }) async => const {'success': true};

  @override
  Future<Map<String, dynamic>> postJson(String path, {Object? body}) async {
    if (path == '/api/user/qrlogin/claim') {
      return {
        'success': true,
        'data': {
          'status': 'confirmed',
          'token': 'qr-token',
          'user': {'id': 9, 'nickname': '扫码用户'},
        },
      };
    }
    return const {'success': true};
  }

  @override
  Stream<NekoSseEvent> sse(String path) async* {
    yield const NekoSseEvent(
      event: 'status',
      data: '{"status":"confirmed"}',
    );
  }
}
