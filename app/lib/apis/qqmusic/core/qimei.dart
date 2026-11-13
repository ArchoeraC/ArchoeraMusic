// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// QIMEI 设备指纹注册（`api.tencentmusic.com` TRPC 代理）。
///
/// QM 移动端协议会把 `comm.QIMEI36` 当作设备身份的一部分：真实的 Android
/// 客户端在启动时先上报设备信息换取服务端签发的 `q16/q36`，之后所有业务
/// 请求都带同一个 `q36`。旧实现把 `QIMEI36` 写死成 `'0'`，等于主动告诉
/// 服务端「我不是客户端」——这是账号级限流（`inner=2001`）最常见的诱因之一。
///
/// 协议（对齐社区实现 L-1124/QQMusicApi `utils/qimei.py`、
/// Suxiaoqinx/QQMusicapi `src/utils/qimei.js`，只做协议事实参考）：
/// 1. 随机 16 字节 `crypt_key`，用内置 RSA 公钥（PKCS#1 v1.5）加密成 `key`；
/// 2. 设备 JSON 用 AES-128-CBC（key = iv = `crypt_key`，PKCS#7）加密成 `params`；
/// 3. `sign = md5(key + params + ts*1000 + nonce + SECRET + extra)`；
/// 4. 响应 `data` 是 JSON 字符串，再取里面的 `data.q16/q36`。
///
/// 结果缓存 24h（服务端建议的刷新周期），随设备身份一起持久化。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/export.dart';

import 'device.dart';

/// 上报端点（TRPC 代理，安卓 QIMEI SDK 的同一入口）。
const String qmQimeiUrl = 'https://api.tencentmusic.com/tme/trpc/proxy';

const String _kPublicKeyPem = '''-----BEGIN PUBLIC KEY-----
MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDEIxgwoutfwoJxcGQeedgP7FG9qaIuS0qzfR8gWkrkTZKM2iWHn2ajQpBRZjMSoSf6+KJGvar2ORhBfpDXyVtZCKpqLQ+FLkpncClKVIrBwv6PHyUvuCb0rIarmgDnzkfQAqVufEtR64iazGDKatvJ9y6B9NMbHddGSAUmRTCrHQIDAQAB
-----END PUBLIC KEY-----''';

const String _kSecret = 'ZdJqM15EeO2zWc08';
const String _kAppKey = '0AND0HD6FE4HY80F';
const String _kChannelId = '10003505';
const String _kPackageId = 'com.tencent.qqmusic';
const String _kSdkVersion = '1.2.13.6';
const String _kSignKey = 'qimei_qq_androidpzAuCmaFAaFaHrdakPjLIEqKrGnSOOvH';

/// 可注入的传输层（测试用 fake；默认 dart:io HttpClient 直连）。
typedef QmQimeiTransport = Future<String> Function(
  String url,
  Map<String, String> headers,
  String body,
);

QmQimeiTransport qmQimeiTransport = _defaultTransport;

Future<String> _defaultTransport(
  String url,
  Map<String, String> headers,
  String body,
) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final req = await client.postUrl(Uri.parse(url));
    headers.forEach((k, v) => req.headers.set(k, v));
    req.add(utf8.encode(body));
    final res = await req.close().timeout(const Duration(seconds: 8));
    final bytes = await res.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    if (res.statusCode != 200) {
      throw HttpException('QIMEI HTTP ${res.statusCode}');
    }
    return utf8.decode(bytes, allowMalformed: true);
  } finally {
    client.close();
  }
}

// ─── 基础密码学（pointycastle） ──────────────────────────────────────────

String _hex(Random rng, int n) {
  const pool = '0123456789abcdef';
  return List<String>.generate(n, (_) => pool[rng.nextInt(16)]).join();
}

class _DerReader {
  _DerReader(this._bytes);

  final Uint8List _bytes;
  int _offset = 0;

  (int, Uint8List) read() {
    final tag = _bytes[_offset++];
    var len = _bytes[_offset++];
    if (len & 0x80 != 0) {
      final n = len & 0x7f;
      len = 0;
      for (var i = 0; i < n; i++) {
        len = (len << 8) | _bytes[_offset++];
      }
    }
    final content = Uint8List.fromList(
      _bytes.sublist(_offset, _offset + len),
    );
    _offset += len;
    return (tag, content);
  }
}

BigInt _toBigInt(List<int> bytes) {
  var out = BigInt.zero;
  for (final b in bytes) {
    out = (out << 8) | BigInt.from(b);
  }
  return out;
}

(BigInt, BigInt)? _cachedRsaKey;

/// 从 SPKI PEM 解出 RSA 的 (n, e)。
(BigInt, BigInt) _rsaPublicKey() {
  final cached = _cachedRsaKey;
  if (cached != null) return cached;
  final b64 = _kPublicKeyPem.replaceAll(
    RegExp(r'-----BEGIN PUBLIC KEY-----|-----END PUBLIC KEY-----|\s'),
    '',
  );
  final der = _DerReader(base64.decode(b64));
  final (_, outer) = der.read();
  final seq = _DerReader(outer);
  seq.read(); // AlgorithmIdentifier
  final (_, bitString) = seq.read();
  final inner = _DerReader(bitString.sublist(1)); // 跳过 unused-bits 字节
  final (_, rsaKey) = inner.read();
  final key = _DerReader(rsaKey);
  final (_, n) = key.read();
  final (_, e) = key.read();
  final pair = (_toBigInt(n), _toBigInt(e));
  _cachedRsaKey = pair;
  return pair;
}

/// RSA PKCS#1 v1.5 加密 → base64。
String _rsaEncryptBase64(String text) {
  final (n, e) = _rsaPublicKey();
  final cipher = PKCS1Encoding(RSAEngine());
  cipher.init(true, PublicKeyParameter<RSAPublicKey>(RSAPublicKey(n, e)));
  return base64.encode(cipher.process(utf8.encode(text)));
}

/// AES-128-CBC（key 同时作为 IV，PKCS#7）→ base64。
String _aesEncryptBase64(String key, String text) {
  final keyBytes = utf8.encode(key);
  final cipher = PaddedBlockCipherImpl(
    PKCS7Padding(),
    CBCBlockCipher(AESEngine()),
  );
  cipher.init(
    true,
    PaddedBlockCipherParameters<CipherParameters, CipherParameters>(
      ParametersWithIV<CipherParameters>(
        KeyParameter(Uint8List.fromList(keyBytes)),
        Uint8List.fromList(keyBytes),
      ),
      null,
    ),
  );
  return base64.encode(cipher.process(Uint8List.fromList(utf8.encode(text))));
}

String _md5Of(List<String> parts) =>
    crypto.md5.convert(utf8.encode(parts.join())).toString();

// ─── 上报负载 ────────────────────────────────────────────────────────────

/// 灯塔 ID（40 段；设备 SDK 的固定格式，缺失会被判为伪造设备）。
String _beaconId(Random rng) {
  final now = DateTime.now().toUtc();
  final monthStart =
      '${now.year}-${now.month.toString().padLeft(2, '0')}-01';
  final rand1 = 100000 + rng.nextInt(900000);
  final rand2 = 100000000 + rng.nextInt(900000000);
  const monthKeys = {1, 2, 13, 14, 17, 18, 21, 22, 25, 26, 29, 30, 33, 34, 37, 38};
  final buf = StringBuffer();
  for (var i = 1; i <= 40; i++) {
    if (monthKeys.contains(i)) {
      buf.write('k$i:$monthStart$rand1.$rand2');
    } else if (i == 3) {
      buf.write('k3:0000000000000000');
    } else if (i == 4) {
      // 非零 hex 串（k4 不允许全零）
      buf.write('k4:${_hex(rng, 16)}'.replaceAll(RegExp(r'^k4:0+$'), 'k4:0'));
    } else {
      buf.write('k$i:${rng.nextInt(10000)}');
    }
    buf.write(';');
  }
  return buf.toString();
}

/// 由 androidId 派生稳定的私网地址（避免每次上报不同网段）。
String _privateIp(String androidId) {
  final digest = crypto.md5.convert(utf8.encode(androidId)).bytes;
  return '192.168.${digest[0]}.${digest[1] % 253 + 2}';
}

Map<String, dynamic> _payload(QqDevice device, Random rng) {
  final profile = device.profile;
  final uptime = DateTime.now().toUtc().subtract(
    Duration(seconds: rng.nextInt(14400)),
  );
  final uptimeStr =
      '${uptime.year}-${uptime.month.toString().padLeft(2, '0')}-'
      '${uptime.day.toString().padLeft(2, '0')} '
      '${uptime.hour.toString().padLeft(2, '0')}:'
      '${uptime.minute.toString().padLeft(2, '0')}:'
      '${uptime.second.toString().padLeft(2, '0')}';
  final reserved = <String, String>{
    'harmony': '0',
    'clone': '0',
    'containe': '',
    'oz': '', // 可选：设备安全字段，缺省由服务端忽略
    'oo': '',
    'kelong': '0',
    'ip': _privateIp(device.androidId),
    'uptimes': uptimeStr,
    'multiUser': '0',
    'bod': profile.board,
    'brd': profile.brand,
    'dv': profile.device,
    'firstLevel': '${profile.sdk}',
    'manufact': profile.manufacturer,
    'name': profile.product,
    'host': profile.host,
    'kernel': 'Linux localhost ${profile.sdk}.0.0',
    'pre': '0',
    'av': '${device.cv}',
    'ch': '',
  };
  return <String, dynamic>{
    'androidId': device.androidId,
    'platformId': 1,
    'appKey': _kAppKey,
    'appVersion': '${device.cv}',
    'beaconIdSrc': _beaconId(rng),
    'brand': profile.brand,
    'channelId': _kChannelId,
    'cid': '',
    'imei': device.imei,
    'imsi': '',
    'mac': '',
    'model': profile.model,
    'networkType': 'wifi',
    'oaid': '',
    'osVersion': 'Android ${profile.osVer},level ${profile.sdk}',
    'qimei': '',
    'qimei36': '',
    'sdkVersion': _kSdkVersion,
    'targetSdkVersion': '${profile.sdk}',
    'audit': '',
    'userId': '{}',
    'packageId': _kPackageId,
    'deviceType': 'Phone',
    'sdkName': '',
    'reserved': jsonEncode(reserved),
  };
}

/// 构造一次上报的 headers + body（便于单测断言形状）。
({Map<String, String> headers, String body}) qmBuildQimeiRequest(
  QqDevice device, {
  Random? random,
}) {
  final rng = random ?? Random.secure();
  final cryptKey = _hex(rng, 16);
  final nonce = _hex(rng, 16);
  final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final extra = jsonEncode(<String, String>{'appKey': _kAppKey});

  final key = _rsaEncryptBase64(cryptKey);
  final params = _aesEncryptBase64(cryptKey, jsonEncode(_payload(device, rng)));
  final sign = _md5Of([
    key,
    params,
    '${ts * 1000}',
    nonce,
    _kSecret,
    extra,
  ]);

  final headers = <String, String>{
    'Host': 'api.tencentmusic.com',
    'method': 'GetQimei',
    'service': 'trpc.tme_datasvr.qimeiproxy.QimeiProxy',
    'appid': 'qimei_qq_android',
    'sign': _md5Of([_kSignKey, '$ts']),
    'user-agent': 'QQMusic',
    'timestamp': '$ts',
    'Content-Type': 'application/json',
  };
  final body = jsonEncode(<String, dynamic>{
    'app': 0,
    'os': 1,
    'qimeiParams': <String, dynamic>{
      'key': key,
      'params': params,
      'time': '$ts',
      'nonce': nonce,
      'sign': sign,
      'extra': extra,
    },
  });
  return (headers: headers, body: body);
}

/// 解析上报响应：`data` 是 JSON 字符串（也兼容已展开的对象形态）。
({String q16, String q36})? qmParseQimeiResponse(String raw) {
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return null;
  }
  if (decoded is! Map) return null;
  final inner = decoded['data'];
  Object? body;
  if (inner is String) {
    try {
      body = jsonDecode(inner);
    } catch (_) {
      return null;
    }
  } else {
    body = inner;
  }
  if (body is! Map) return null;
  final data = body['data'];
  if (data is! Map) return null;
  final q16 = '${data['q16'] ?? ''}'.trim();
  final q36 = '${data['q36'] ?? ''}'.trim();
  if (q16.isEmpty || q36.isEmpty) return null;
  return (q16: q16, q36: q36);
}

/// 进行中的注册（并发去重：同一时刻只上报一次）。
Future<QqDevice>? _pending;

/// 确保设备带有可用 QIMEI；失败时返回原设备（业务请求继续，只是不带 QIMEI）。
///
/// [force] = true 强制重新上报（仅诊断/重置设备时使用）。
Future<QqDevice> qmEnsureQimei({bool force = false}) {
  final device = qmGetDevice();
  if (!force && device.qimeiFresh) return Future.value(device);
  final pending = _pending;
  if (pending != null) return pending;

  final future = () async {
    try {
      final req = qmBuildQimeiRequest(device);
      final raw = await qmQimeiTransport(qmQimeiUrl, req.headers, req.body);
      final parsed = qmParseQimeiResponse(raw);
      if (parsed == null) return device;
      final updated = device.copyWith(
        qimei16: parsed.q16,
        qimei36: parsed.q36,
        qimeiSavedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      );
      qmSaveDevice(updated);
      return updated;
    } catch (_) {
      // 上报失败不阻断业务：宁可不带 QIMEI，也不要让搜索/播放一起挂掉。
      return device;
    }
  }();

  _pending = future;
  future.whenComplete(() {
    if (identical(_pending, future)) _pending = null;
  });
  return future;
}

/// 测试用：清空注册去重状态与 RSA 公钥缓存。
void qmResetQimeiState() {
  _pending = null;
  _cachedRsaKey = null;
}
