/// xeapi 公钥获取与会话状态（Dart 移植）——对齐 apis/netease/core/xeapi.ts。
///
/// 反爬接口（如游客注册）走 xeapi：先向 /api/gorilla/anti/crawler/security/key/get
/// 拉取 X25519 公钥包（缓存于进程），首次请求后服务端经响应头下发会话密钥，后续请求复用。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'config.dart';
import 'crypto.dart';

NmXeapiPublicKey? _publicKeyState;
String _sessionId = '';
String _sessionKey = '';

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
Future<NmXeapiPublicKey> _fetchPublicKey(String deviceId, String currentKeyVersion) async {
  final nonce = _generateNonce();
  final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
  final data = <String, String>{
    'appVersion': '9.1.65',
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
        .postUrl(Uri.parse('$nmApiDomain/api/gorilla/anti/crawler/security/key/get'))
        .timeout(const Duration(seconds: 8));
    req.headers.set('User-Agent', nmUaMap['api']!['android']!);
    req.headers.set('Content-Type', 'application/x-www-form-urlencoded');
    req.headers.set('Cookie', deviceId.isEmpty ? '' : 'deviceId=${Uri.encodeComponent(deviceId)}');
    req.write(Uri(queryParameters: data).query);
    final res = await req.close().timeout(const Duration(seconds: 8));
    final text = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 8));

    final json = jsonDecode(text) as Map<String, dynamic>;
    final payload = json['data'] as Map<String, dynamic>?;
    if (json['code'] != 200 || payload == null || payload['encryptedData'] == null) {
      throw const HttpException('xeapi public key request failed');
    }
    final signature = payload['signature']?.toString();
    if (signature == null ||
        nmXeapiSign(payload['timestamp']?.toString() ?? '', nonce) != signature) {
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
Future<NmXeapiPublicKey> nmEnsureXeapiKey(String deviceId) async {
  if (_publicKeyState?.sk != null && _publicKeyState!.sk!.isNotEmpty) return _publicKeyState!;
  final key = await _fetchPublicKey(deviceId, _publicKeyState?.version ?? '');
  if ((key.sk == null || key.sk!.isEmpty) &&
      _publicKeyState?.sk != null &&
      _publicKeyState!.sk!.isNotEmpty) {
    key.sk = _publicKeyState!.sk;
  }
  _publicKeyState = key;
  return key;
}

/// xeapi 会话信息（含公钥状态，供请求层构造加密体）
class XeapiSession {
  XeapiSession({
    this.publicKeyState,
    required this.sessionId,
    required this.sessionKey,
  });

  final NmXeapiPublicKey? publicKeyState;
  final String sessionId;
  final String sessionKey;
}

/// 读取当前会话（首次请求为空）（对齐 getXeapiSession）
XeapiSession nmGetXeapiSession() => XeapiSession(
      publicKeyState: _publicKeyState,
      sessionId: _sessionId,
      sessionKey: _sessionKey,
    );

/// 服务端响应头下发的会话密钥（对齐 updateXeapiSession）
void nmUpdateXeapiSession(String id, String key) {
  _sessionId = id;
  _sessionKey = key;
}

/// 失效时清空（下次重新拉取）（对齐 resetXeapiKey）
void nmResetXeapiKey() {
  _publicKeyState = null;
  _sessionId = '';
  _sessionKey = '';
}
