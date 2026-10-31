// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// NekoMusic 客户端实例身份（`neko-client-v1`）端到端单测：
// 注册 → 每请求 ECDSA 签名 → 401 invalid 后重新注册并重试。
//
// 用本地 HttpServer 扮演服务端：按后端 `ClientIdentityProtocol` 的签名串与
// `public_key`（SPKI DER）真实验签，确保 Dart 侧的规范化串 / 签名 / 请求头与
// 服务端逐字节一致（字段顺序或编码漂移会直接导致验签失败）。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';

import 'package:archoera_music/apis/neko/neko_client.dart';
import 'package:archoera_music/services/neko/neko_instance_identity.dart';

void main() {
  late Directory tempDir;

  const testClientId = 'nkc_pub_testclient000000';

  setUp(() {
    NekoInstanceIdentity.debugClearPool();
    NekoInstanceIdentity.debugClientId = testClientId;
    tempDir = Directory.systemTemp.createTempSync('neko_identity_test');
    NekoInstanceIdentity.debugStorePath =
        '${tempDir.path}/neko_client_identity.json';
  });

  tearDown(() {
    NekoInstanceIdentity.debugClientId = null;
    NekoInstanceIdentity.debugStorePath = null;
    NekoInstanceIdentity.debugClearPool();
    tempDir.deleteSync(recursive: true);
  });

  test('注册 → 请求签名 → 401 invalid 后重新注册并重试', () async {
    final fake = _FakeNekoServer();
    await fake.start();
    addTearDown(fake.stop);

    final client = NekoClient(baseUrl: fake.baseUrl);
    final data = await client.getJson('/api/music/search', query: {'q': '喵'});

    expect((data['data'] as Map)['hits'], 1);
    expect(fake.registerCount, 1, reason: '首次请求应完成一次实例注册');
    expect(fake.tokenRefreshes, 0, reason: '令牌未临近过期时不应续签');
    expect(fake.signedRequests, 1);
    expect(fake.lastSignatureValid, isTrue, reason: '服务端必须验签通过');
    expect(fake.lastInstanceId, fake.registeredInstanceId);

    // 第二次请求复用同一实例与令牌（不重复注册）。
    await client.getJson('/api/music/search', query: {'q': 'a'});
    expect(fake.registerCount, 1);
    expect(fake.signedRequests, 2);

    // 服务端判定身份失效：客户端应续签 / 重新注册后自动重试一次。
    fake.rejectNextSignedRequest = true;
    final retried = await client.getJson('/api/music/search', query: {'q': 'b'});
    expect((retried['data'] as Map)['hits'], 1, reason: '身份恢复后应自动重试成功');
    expect(fake.rejections, 1);
    expect(fake.lastSignatureValid, isTrue);
  });

  test('身份持久化：新实例复用已登记的私钥与令牌（不重复注册）', () async {
    final fake = _FakeNekoServer();
    await fake.start();
    addTearDown(fake.stop);

    await NekoClient(
      baseUrl: fake.baseUrl,
    ).getJson('/api/music/search', query: {'q': 'x'});
    expect(fake.registerCount, 1);
    final instanceId = fake.registeredInstanceId;

    // 模拟重启：丢弃内存缓存，仅保留磁盘上的身份。
    NekoInstanceIdentity.debugClearPool();
    await NekoClient(
      baseUrl: fake.baseUrl,
    ).getJson('/api/music/search', query: {'q': 'y'});

    expect(fake.registerCount, 1, reason: '令牌仍在有效期内，不重新注册');
    expect(fake.tokenRefreshes, 0);
    expect(fake.lastInstanceId, instanceId);
    expect(fake.lastSignatureValid, isTrue);
  });

  test('401 用户令牌失效 → 回调宿主播清会话；客户端身份失效不触发', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));

    var identityInvalid = false;
    var protectedHits = 0;
    server.listen((req) async {
      final res = req.response..headers.contentType = ContentType.json;
      final path = req.uri.path;
      if (path == '/api/client/challenge' || path == '/api/replay/challenge') {
        // 旧服务端：无挑战接口 → 跳过身份签名、直接领取 nonce。
        res.statusCode = 404;
        res.write('{}');
      } else if (path == '/api/replay/nonce') {
        res.write(
          jsonEncode({
            'success': true,
            'data': {
              'nonces': {
                'read': ['r1'],
                'write': ['w1'],
              },
            },
          }),
        );
      } else {
        protectedHits++;
        res.statusCode = 401;
        if (identityInvalid) {
          res.headers.set(kNekoClientStatusHeader, 'invalid');
        }
        res.write(jsonEncode({'success': false, 'message': '无效的认证令牌'}));
      }
      await res.close();
    });

    final client = NekoClient(
      baseUrl: 'http://127.0.0.1:${server.port}',
      token: 'stale-token',
    );
    var cleared = 0;
    var lastMessage = '';
    client.onUnauthorized = (message) {
      cleared++;
      lastMessage = message;
    };

    await expectLater(
      client.getJson('/api/user/favorites'),
      throwsA(isA<NekoApiException>()),
    );
    expect(cleared, 1, reason: '用户令牌失效应通知宿主清理会话');
    expect(lastMessage, '无效的认证令牌', reason: '回调需带服务端文案便于定位');

    // 客户端实例身份失效（带 X-Neko-Client-Status: invalid）不应误清用户会话。
    identityInvalid = true;
    await expectLater(
      client.getJson('/api/user/favorites'),
      throwsA(isA<NekoApiException>()),
    );
    expect(cleared, 1, reason: '身份失效只重试，不清用户会话');
    expect(protectedHits, 3, reason: '身份失效重试一次');
  });

  test('显式清空 client_id：直接拒绝签名（fail-closed）', () async {
    // 生产默认内置本项目自有标识；显式置空用于验证「无标识的构建不联网」。
    NekoInstanceIdentity.debugClientId = '';
    final identity = NekoInstanceIdentity.forBaseUrl('https://neko.invalid');
    await expectLater(
      identity.signHeaders(
        method: 'GET',
        uri: Uri.parse('https://neko.invalid/api/user/favorites'),
        body: const <int>[],
      ),
      throwsA(
        isA<NekoIdentityException>().having(
          (e) => e.message,
          'message',
          contains('NEKO_CLIENT_ID'),
        ),
      ),
    );
  });

  test('连续 3 次身份被拒 → 熔断，不再反复注册', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));

    var protectedHits = 0;
    server.listen((req) async {
      final res = req.response..headers.contentType = ContentType.json;
      final path = req.uri.path;
      if (path == '/api/client/challenge') {
        res.write(
          jsonEncode({
            'success': true,
            'data': {
              'protocol': kNekoIdentityProtocol,
              'challenge': 'c',
            },
          }),
        );
      } else if (path == '/api/client/register' ||
          path == '/api/client/token') {
        res.statusCode = 401;
        res.write(jsonEncode({'success': false, 'message': '客户端已停用'}));
      } else if (path == '/api/replay/challenge') {
        res.statusCode = 404;
        res.write('{}');
      } else if (path == '/api/replay/nonce') {
        res.write(
          jsonEncode({
            'success': true,
            'data': {
              'nonces': {
                'read': ['r1', 'r2', 'r3', 'r4'],
                'write': ['w1', 'w2', 'w3', 'w4'],
              },
            },
          }),
        );
      } else {
        protectedHits++;
        res.statusCode = 401;
        res.headers.set(kNekoClientStatusHeader, 'invalid');
        res.write(jsonEncode({'success': false, 'message': '客户端身份无效'}));
      }
      await res.close();
    });

    final client = NekoClient(baseUrl: 'http://127.0.0.1:${server.port}');
    for (var i = 0; i < 3; i++) {
      await expectLater(
        client.getJson('/api/user/favorites'),
        throwsA(isA<NekoApiException>()),
      );
    }
    expect(
      NekoInstanceIdentity.forBaseUrl('http://127.0.0.1:${server.port}').blocked,
      isTrue,
      reason: '连续三次被拒应熔断',
    );
    final hitsBefore = protectedHits;
    await expectLater(
      client.getJson('/api/user/favorites'),
      throwsA(isA<NekoApiException>()),
    );
    expect(protectedHits, hitsBefore, reason: '熔断后不再向服务端发请求');
  });

  test('规范化串字段顺序与服务端一致（neko-client-v1）', () {    final canonical = nekoCanonicalRequest(
      method: 'post',
      path: '/api/music/search',
      query: 'q=a+b',
      clientId: testClientId,
      instanceId: '11111111-2222-4333-8444-555555555555',
      platform: kNekoIdentityPlatform,
      timestampSeconds: 1700000000,
      bodyHash: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      nonce: 'n-1',
    );
    expect(canonical.split('\n'), [
      'neko-client-v1',
      'POST',
      '/api/music/search',
      'q=a+b',
      testClientId,
      '11111111-2222-4333-8444-555555555555',
      'pc',
      '1700000000',
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      'n-1',
    ]);
  });
}

// ── 假服务端（按后端协议真实验签）────────────────────────────────

class _FakeNekoServer {
  HttpServer? _server;

  String get baseUrl => 'http://127.0.0.1:${_server!.port}';

  int registerCount = 0;
  int tokenRefreshes = 0;
  int signedRequests = 0;
  int rejections = 0;
  bool rejectNextSignedRequest = false;

  String registeredInstanceId = '';
  String _registeredKey = '';
  String _token = '';
  String? lastInstanceId;
  bool lastSignatureValid = false;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_handle);
  }

  Future<void> stop() async => _server?.close(force: true);

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    final response = req.response..headers.contentType = ContentType.json;
    final body = await utf8.decoder.bind(req).join();

    switch (path) {
      case '/api/client/challenge':
        await _json(response, {
          'success': true,
          'data': {
            'protocol': kNekoIdentityProtocol,
            'challenge': 'challenge-$path',
          },
        });
        return;
      case '/api/client/register':
        final json = jsonDecode(body) as Map<String, dynamic>;
        registerCount++;
        final canonical = [
          'neko-client-register-v1',
          json['client_id'],
          json['platform'],
          json['instance_id'],
          json['public_key'],
          json['challenge'],
          '${json['timestamp']}',
        ].join('\n');
        if (!_verify(
          json['public_key'] as String,
          canonical,
          json['signature'] as String,
        )) {
          response.statusCode = 401;
          await _json(response, {'success': false, 'message': '客户端实例注册被拒'});
          return;
        }
        registeredInstanceId = json['instance_id'] as String;
        _registeredKey = json['public_key'] as String;
        _token = 'token-$registerCount';
        await _json(response, {
          'success': true,
          'data': {
            'instance_id': registeredInstanceId,
            'token': _token,
            'expires_at': _nowSeconds + 30 * 24 * 60 * 60,
          },
        });
        return;
      case '/api/client/token':
        final json = jsonDecode(body) as Map<String, dynamic>;
        tokenRefreshes++;
        final canonical = [
          'neko-client-token-v1',
          json['client_id'],
          json['platform'],
          json['instance_id'],
          json['challenge'],
          '${json['timestamp']}',
        ].join('\n');
        if ((json['instance_id'] as String) != registeredInstanceId ||
            !_verify(
              _registeredKey,
              canonical,
              json['signature'] as String,
            )) {
          response.statusCode = 401;
          await _json(response, {'success': false, 'message': '续签被拒'});
          return;
        }
        _token = 'token-refreshed-$tokenRefreshes';
        await _json(response, {
          'success': true,
          'data': {
            'instance_id': registeredInstanceId,
            'token': _token,
            'expires_at': _nowSeconds + 30 * 24 * 60 * 60,
          },
        });
        return;
      case '/api/replay/challenge':
        // 旧服务端：无挑战接口 → 客户端回退为直接领取 nonce。
        response.statusCode = 404;
        await _json(response, {'success': false});
        return;
      case '/api/replay/nonce':
        await _json(response, {
          'success': true,
          'data': {
            'nonces': {
              'read': ['read-1', 'read-2'],
              'write': ['write-1'],
            },
          },
        });
        return;
    }

    signedRequests++;
    lastInstanceId = req.headers.value(kNekoClientInstanceHeader);
    final timestamp =
        int.tryParse(req.headers.value(kNekoClientTimestampHeader) ?? '') ?? 0;
    final nonce = req.headers.value('X-Neko-Nonce') ?? '';
    final canonical = nekoCanonicalRequest(
      method: req.method,
      path: path,
      query: req.uri.query,
      clientId: req.headers.value(kNekoClientIdHeader) ?? '',
      instanceId: lastInstanceId ?? '',
      platform: kNekoIdentityPlatform,
      timestampSeconds: timestamp,
      bodyHash: crypto.sha256.convert(utf8.encode(body)).toString(),
      nonce: nonce,
    );
    final signature = req.headers.value(kNekoClientSignatureHeader) ?? '';
    lastSignatureValid = lastInstanceId == registeredInstanceId &&
        req.headers.value(kNekoClientTokenHeader) == _token &&
        _verify(_registeredKey, canonical, signature);

    if (rejectNextSignedRequest) {
      rejectNextSignedRequest = false;
      rejections++;
      response.statusCode = 401;
      response.headers.set(kNekoClientStatusHeader, 'invalid');
      await _json(response, {'success': false, 'message': '客户端实例身份失效'});
      return;
    }
    if (!lastSignatureValid) {
      response.statusCode = 401;
      response.headers.set(kNekoClientStatusHeader, 'invalid');
      await _json(response, {'success': false, 'message': '签名校验失败'});
      return;
    }
    await _json(response, {
      'success': true,
      'data': {'hits': 1},
    });
  }

  static Future<void> _json(
    HttpResponse response,
    Map<String, dynamic> data,
  ) async {
    response.write(jsonEncode(data));
    await response.close();
  }

  static int get _nowSeconds =>
      DateTime.now().millisecondsSinceEpoch ~/ 1000;

  static bool _verify(String spkiB64, String canonical, String signatureB64) {
    try {
      final spki = base64Url.decode(base64Url.normalize(spkiB64));
      final rawPoint = spki.sublist(spki.length - 65);
      final curve = ECCurve_prime256v1();
      final publicKey = ECPublicKey(curve.curve.decodePoint(rawPoint), curve);
      final signer = ECDSASigner(SHA256Digest(), HMac.withDigest(SHA256Digest()))
        ..init(false, PublicKeyParameter<ECPublicKey>(publicKey));
      final der = base64Url.decode(base64Url.normalize(signatureB64));
      final (r, s) = _derToPair(der);
      return signer.verifySignature(
        Uint8List.fromList(utf8.encode(canonical)),
        ECSignature(r, s),
      );
    } catch (_) {
      return false;
    }
  }

  static (BigInt, BigInt) _derToPair(List<int> der) {
    var offset = 0;
    expect(der[offset++], 0x30);
    offset += _lengthSize(der, offset) + 1;
    expect(der[offset++], 0x02);
    final rLength = der[offset];
    final r = BigInt.parse(
      der.sublist(offset + 1, offset + 1 + rLength).map(_hex).join(),
      radix: 16,
    );
    offset += 1 + rLength;
    expect(der[offset++], 0x02);
    final sLength = der[offset];
    final s = BigInt.parse(
      der.sublist(offset + 1, offset + 1 + sLength).map(_hex).join(),
      radix: 16,
    );
    return (r, s);
  }

  static int _lengthSize(List<int> der, int offset) =>
      (der[offset] & 0x80) == 0 ? 0 : der[offset] & 0x7f;

  static String _hex(int value) => value.toRadixString(16).padLeft(2, '0');
}
