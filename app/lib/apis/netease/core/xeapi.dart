// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// xeapi 公钥获取与会话状态（Dart 移植）——对齐 apis/netease/core/xeapi.ts。
///
/// 反爬接口（如游客注册、song_url）走 xeapi：先向 `/api/bsr/sk/get`
/// 拉取 X25519 公钥包（缓存于进程），首次请求后服务端经响应头下发会话密钥，
/// 后续请求复用。
///
/// 上游 2026-10-10（SPlayer-Next 7c2aea7d46）把公钥端点从旧的
/// `/api/gorilla/anti/crawler/security/key/get` 换到 `/api/bsr/sk/get`，
/// 客户端版本升到 9.5.61，并给公钥/会话加了并发去重与代际号：
/// 登出（[nmResetXeapiKey]）期间迟到的响应不得恢复旧会话密钥。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'config.dart';
import 'crypto.dart';

NmXeapiPublicKey? _publicKeyState;
String _sessionId = '';
String _sessionKey = '';

/// 在途公钥请求（并发去重：多个接口同时首次调用只拉一次）。
Future<NmXeapiPublicKey>? _publicKeyPromise;

/// 会话代际号：reset 后递增，迟到的公钥/会话响应据此丢弃。
int _publicKeyGeneration = 0;

/// 16 位数字 nonce（对齐 generateNonce）
String _generateNonce() {
  final rng = Random.secure();
  final buf = StringBuffer();
  for (var i = 0; i < 16; i++) {
    buf.write(rng.nextInt(10));
  }
  return buf.toString();
}

/// 向反爬接口拉取并解密公钥包（对齐 fetchPublicKey）
Future<NmXeapiPublicKey> _fetchPublicKey(
  String deviceId,
  String currentKeyVersion,
) async {
  final nonce = _generateNonce();
  final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
  final data = <String, String>{
    'appVersion': '9.5.61',
    'currentKeyVersion': currentKeyVersion,
    'deviceId': deviceId,
    'nonce': nonce,
    'os': 'android',
    'requestType': 'active',
    'signature': nmXeapiSign(timestamp, nonce),
    't1': '',
    't2': '',
    'timestamp': timestamp,
    'uid': '',
  };

  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final req = await client
        .postUrl(Uri.parse('$nmApiDomain/api/bsr/sk/get'))
        .timeout(const Duration(seconds: 8));
    req.headers.set('User-Agent', nmUaMap['api']!['android']!);
    req.headers.set('Content-Type', 'application/x-www-form-urlencoded');
    req.headers.set(
      'Cookie',
      deviceId.isEmpty ? '' : 'deviceId=${Uri.encodeComponent(deviceId)}',
    );
    req.write(nmFormUrlEncode(data));
    final res = await req.close().timeout(const Duration(seconds: 8));
    final text = await res
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 8));

    final json = jsonDecode(text) as Map<String, dynamic>;
    final payload = json['data'] as Map<String, dynamic>?;
    if (json['code'] != 200 ||
        payload == null ||
        payload['encryptedData'] == null) {
      throw const HttpException('xeapi public key request failed');
    }
    final signature = payload['signature']?.toString();
    if (signature == null ||
        nmXeapiSign(payload['timestamp']?.toString() ?? '', nonce) !=
            signature) {
      throw const HttpException('xeapi public key response signature mismatch');
    }
    final key = nmXeapiDecryptPublicKey(payload['encryptedData']!.toString());
    if (key.sk == null || key.sk!.isEmpty) {
      throw const HttpException('xeapi public key response missing sk');
    }
    return key;
  } finally {
    client.close(force: true);
  }
}

/// 确保已有公钥（缺失则拉取并缓存），返回当前公钥状态（对齐 ensureXeapiKey）
Future<NmXeapiPublicKey> nmEnsureXeapiKey(String deviceId) {
  final existing = _publicKeyState;
  if (existing?.sk != null && existing!.sk!.isNotEmpty) {
    return Future.value(existing);
  }
  final pending = _publicKeyPromise;
  if (pending != null) return pending;

  final generation = _publicKeyGeneration;
  late final Future<NmXeapiPublicKey> future;
  future = _fetchPublicKey(deviceId, _publicKeyState?.version ?? '')
      .then((key) {
        // 新版公钥包没带 sk 时沿用旧 sk（服务端轮换窗口）。
        if ((key.sk == null || key.sk!.isEmpty) &&
            _publicKeyState?.sk != null &&
            _publicKeyState!.sk!.isNotEmpty) {
          key.sk = _publicKeyState!.sk;
        }
        if (generation == _publicKeyGeneration) _publicKeyState = key;
        return key;
      })
      .whenComplete(() {
        if (identical(_publicKeyPromise, future)) _publicKeyPromise = null;
      });
  _publicKeyPromise = future;
  return future;
}

/// xeapi 会话信息（含公钥状态，供请求层构造加密体）
class XeapiSession {
  XeapiSession({
    this.publicKeyState,
    required this.sessionId,
    required this.sessionKey,
    required this.generation,
  });

  final NmXeapiPublicKey? publicKeyState;
  final String sessionId;
  final String sessionKey;

  /// 读取时的会话代际号；响应回写时必须带回，防止迟到响应污染新会话。
  final int generation;
}

/// 读取当前会话（首次请求为空）（对齐 getXeapiSession）
XeapiSession nmGetXeapiSession() => XeapiSession(
  publicKeyState: _publicKeyState,
  sessionId: _sessionId,
  sessionKey: _sessionKey,
  generation: _publicKeyGeneration,
);

/// 服务端响应头下发的会话密钥（对齐 updateXeapiSession）
///
/// [generation] 与请求发起时的代际号不一致（期间登出 / reset）则丢弃。
void nmUpdateXeapiSession(String id, String key, int generation) {
  if (generation != _publicKeyGeneration) return;
  _sessionId = id;
  _sessionKey = key;
}

/// 失效时清空（下次重新拉取）（对齐 resetXeapiKey）
void nmResetXeapiKey() {
  _publicKeyGeneration += 1;
  _publicKeyState = null;
  _publicKeyPromise = null;
  _sessionId = '';
  _sessionKey = '';
}
