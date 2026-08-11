/// 网易云 API 加解密层（Dart 移植）——对齐 apis/netease/core/crypto.ts。
///
/// - weapi：AES-CBC(PRESET_KEY) → AES-CBC(secretKey) → RSA 裸加密(encSecKey)
/// - eapi：AES-ECB(hex 大写)，签名 = md5(`nobody${url}use${text}md5forencrypt`)
/// - linuxapi：AES-ECB(hex 大写)
///
/// 加密基础库用 pointycastle（AES）+ Dart 内置 BigInt（RSA 模幂）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/export.dart';

import 'config.dart';

/// AES-128 加密（PKCS7 填充）；[cbc] 为 true 时用 CBC + 固定 IV，否则 ECB。
Uint8List _aes128(String text, String key, {required bool cbc}) {
  final block = cbc
      ? CBCBlockCipher(AESEngine()) as BlockCipher
      : ECBBlockCipher(AESEngine()) as BlockCipher;
  final cipher = PaddedBlockCipherImpl(PKCS7Padding(), block);
  final keyParam = KeyParameter(utf8.encode(key));
  final params = cbc
      ? PaddedBlockCipherParameters<CipherParameters, CipherParameters>(
          ParametersWithIV<CipherParameters>(keyParam, utf8.encode(nmIv)),
          null,
        )
      : PaddedBlockCipherParameters<CipherParameters, CipherParameters>(
          keyParam,
          null,
        );
  cipher.init(true, params);
  return cipher.process(utf8.encode(text));
}

/// AES-CBC 加密 → base64（weapi 用）
String nmAesCbcBase64(String text, String key) =>
    base64.encode(_aes128(text, key, cbc: true));

/// AES-ECB 加密 → 大写 hex（eapi/linuxapi 用）
String nmAesEcbHexUpper(String text, String key) {
  final bytes = _aes128(text, key, cbc: false);
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
}

// ─── RSA 裸加密（RSA_NO_PADDING，对齐 node:crypto publicEncrypt） ────────

/// 简易 DER 游标（SPKI/RSAPublicKey 结构足够用）
class _Der {
  _Der(this._d);

  final List<int> _d;
  int _p = 0;

  /// 读一个 TLV，返回 (tag, content)
  (int, Uint8List) read() {
    final tag = _d[_p++];
    var len = _d[_p++];
    if (len & 0x80 != 0) {
      final n = len & 0x7f;
      len = 0;
      for (var k = 0; k < n; k++) {
        len = (len << 8) | _d[_p++];
      }
    }
    final content = Uint8List.fromList(_d.sublist(_p, _p + len));
    _p += len;
    return (tag, content);
  }
}

BigInt _bytesToBigInt(List<int> bytes) {
  var result = BigInt.zero;
  for (final b in bytes) {
    result = (result << 8) | BigInt.from(b);
  }
  return result;
}

(BigInt, BigInt)? _rsaKey;

/// 从 SPKI PEM 提取 RSA 模数 n 与指数 e
(BigInt, BigInt) _parseRsaPublicKey() {
  final cached = _rsaKey;
  if (cached != null) return cached;
  final b64 = nmPublicKey.replaceAll(
    RegExp(r'-----BEGIN PUBLIC KEY-----|-----END PUBLIC KEY-----|\s'),
    '',
  );
  final der = _Der(base64.decode(b64));
  final (_, outer) = der.read(); // SEQUENCE（整包）
  final seq = _Der(outer);
  seq.read(); // SEQUENCE（算法 OID + NULL）
  final (_, bitStr) = seq.read(); // BIT STRING
  final bits = _Der(bitStr.sublist(1)); // 跳过未使用位字节（0x00）
  final (_, inner) = bits.read(); // SEQUENCE（RSAPublicKey）
  final iseq = _Der(inner);
  final (_, nBytes) = iseq.read(); // INTEGER n
  final (_, eBytes) = iseq.read(); // INTEGER e
  final key = (_bytesToBigInt(nBytes), _bytesToBigInt(eBytes));
  _rsaKey = key;
  return key;
}

/// RSA 裸加密：明文左侧补 0 到 128 字节，整体模幂，输出 256 位小写 hex
String nmRsaEncrypt(String str) {
  final (n, e) = _parseRsaPublicKey();
  final data = utf8.encode(str);
  final padded = Uint8List(128)..setAll(128 - data.length, data);
  var m = BigInt.zero;
  for (final b in padded) {
    m = (m << 8) | BigInt.from(b);
  }
  final c = m.modPow(e, n);
  final hex = c.toRadixString(16).padLeft(256, '0');
  return hex;
}

// ─── weapi / eapi / linuxapi ────────────────────────────────────────────

/// weapi 加密 → { params, encSecKey }
({String params, String encSecKey}) nmWeapi(Map<String, dynamic> object) {
  final text = jsonEncode(object);
  final rng = Random.secure();
  final buf = StringBuffer();
  for (var i = 0; i < 16; i++) {
    buf.write(nmBase62[rng.nextInt(62)]);
  }
  final secretKey = buf.toString();
  final first = nmAesCbcBase64(text, nmPresetKey);
  final params = nmAesCbcBase64(first, secretKey);
  final encSecKey = nmRsaEncrypt(secretKey.split('').reversed.join());
  return (params: params, encSecKey: encSecKey);
}

/// eapi 加密 → params（大写 hex）
String nmEapi(String url, Object object) {
  final text = object is Map ? jsonEncode(object) : object.toString();
  final message = 'nobody${url}use${text}md5forencrypt';
  final digest = crypto.md5.convert(utf8.encode(message)).toString();
  final data = '$url-36cd479b6b5-$text-36cd479b6b5-$digest';
  return nmAesEcbHexUpper(data, nmEapiKey);
}

/// linuxapi 加密 → eparams（大写 hex）
String nmLinuxapi(Map<String, dynamic> object) =>
    nmAesEcbHexUpper(jsonEncode(object), nmLinuxApiKey);

// ─── eapi 响应解密（e_r=true 时服务端返回 AES-ECB 加密体） ──────────────

/// hex 字符串 → 字节数组
Uint8List _hexToBytes(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// AES-128-ECB 加解密（PKCS7 填充，对齐 node:crypto createCipheriv/createDecipheriv）
Uint8List _aesEcbBytes(Uint8List input, Uint8List key, {required bool encrypt}) {
  final cipher = PaddedBlockCipherImpl(PKCS7Padding(), ECBBlockCipher(AESEngine()));
  cipher.init(encrypt, PaddedBlockCipherParameters<CipherParameters, CipherParameters>(
    KeyParameter(key),
    null,
  ));
  return cipher.process(input);
}

/// eapi 响应解密（对齐 eapiResDecrypt；aeapi 时服务端响应为 gzip 压缩）。
/// 密文是二进制，必须先解 AES 再判断 gzip 魔数，不能在解密前 utf8.decode。
dynamic nmEapiResDecrypt(String encryptedHex, {bool aeapi = false}) {
  try {
    final decrypted = _aesEcbBytes(_hexToBytes(encryptedHex), utf8.encode(nmEapiKey), encrypt: false);
    final isGzip = decrypted.length >= 2 && decrypted[0] == 0x1f && decrypted[1] == 0x8b;
    final bytes = isGzip ? GZipCodec().decode(decrypted) : decrypted;
    if (aeapi && !isGzip) return null;
    return jsonDecode(utf8.decode(bytes));
  } catch (_) {
    return null;
  }
}

// ─── xeapi 反爬加密（对齐 crypto.ts 末尾 xeapi 段） ──────────────────────

/// xeapi 签名密钥
const nmXeapiSignKey = 'b1ced3e7b84e4c3f9c1ef8a7d6b2e4f1';
/// xeapi 静态密钥（密文外层 AES 加密）
final Uint8List _xeapiStaticKey = Uint8List.fromList(utf8.encode('0CoJUm6Qyw8W8jud'));
/// X25519 基点（u 坐标 = 9）
final Uint8List _x25519BasePoint = Uint8List(32)..[0] = 9;

/// 反爬公钥结构（对齐 XeapiPublicKey）
class NmXeapiPublicKey {
  NmXeapiPublicKey({required this.version, required this.publicKey, this.sk});

  final String version;
  final String publicKey;
  String? sk;
}

/// xeapi 加密选项（对齐 XeapiOptions）
class NmXeapiOptions {
  NmXeapiOptions({
    required this.publicKeyState,
    this.sessionId,
    this.sessionKey,
    this.os,
    this.method,
    this.contentType,
  });

  final NmXeapiPublicKey publicKeyState;
  final String? sessionId;
  final String? sessionKey;
  final String? os;
  final String? method;
  final String? contentType;
}

/// 加密安全随机字节
Uint8List _randomBytes(int n) {
  final rng = Random.secure();
  return Uint8List.fromList(List.generate(n, (_) => rng.nextInt(256)));
}

/// HMAC-SHA256
Uint8List _hmacSha256(List<int> key, List<int> data) =>
    Uint8List.fromList(crypto.Hmac(crypto.sha256, key).convert(data).bytes);

/// X25519 标量乘法（RFC 7748 Montgomery ladder）。
/// pointycastle 4.0 不含 X25519（仅 Weierstrass 曲线），故用纯 BigInt 实现：
/// 输入 scalar（将被 clamp）与 u 坐标各 32 字节，输出 32 字节共享密钥。
Uint8List _x25519(Uint8List scalar, Uint8List u) {
  final k = Uint8List.fromList(scalar);
  k[0] &= 248;
  k[31] &= 127;
  k[31] |= 64;

  final p = (BigInt.one << 255) - BigInt.from(19);
  final a24 = BigInt.from(121665);

  BigInt decode(Uint8List b) {
    var r = BigInt.zero;
    for (var i = b.length - 1; i >= 0; i--) {
      r = (r << 8) | BigInt.from(b[i]);
    }
    return r;
  }

  Uint8List encode(BigInt v) {
    final out = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      out[i] = (v & BigInt.from(0xff)).toInt();
      v = v >> 8;
    }
    return out;
  }

  final x1 = decode(u);
  var x2 = BigInt.one;
  var z2 = BigInt.zero;
  var x3 = x1;
  var z3 = BigInt.one;
  var swap = 0;

  for (var t = 254; t >= 0; t--) {
    final kt = (k[t >> 3] >> (t & 7)) & 1;
    swap ^= kt;
    if (swap == 1) {
      var tmp = x2;
      x2 = x3;
      x3 = tmp;
      tmp = z2;
      z2 = z3;
      z3 = tmp;
    }
    swap = kt;

    final a = (x2 + z2) % p;
    final aa = (a * a) % p;
    final b = (x2 - z2) % p;
    final bb = (b * b) % p;
    final e = (aa - bb) % p;
    final c = (x3 + z3) % p;
    final d = (x3 - z3) % p;
    final da = (d * a) % p;
    final cb = (c * b) % p;
    x3 = ((da + cb) * (da + cb)) % p;
    z3 = (x1 * ((da - cb) * (da - cb))) % p;
    x2 = (aa * bb) % p;
    z2 = (e * ((aa + a24 * e) % p)) % p;
  }

  if (swap == 1) {
    var tmp = x2;
    x2 = x3;
    x3 = tmp;
    tmp = z2;
    z2 = z3;
    z3 = tmp;
  }

  final zInv = z2.modPow(p - BigInt.from(2), p);
  return encode((x2 * zInv) % p);
}

/// AES-128-GCM 加密 → 密文 + 16 字节认证标签（对齐 createCipheriv('aes-128-gcm') + getAuthTag）
Uint8List _aesGcmEncrypt(Uint8List key, Uint8List iv, Uint8List plaintext) {
  final gcm = GCMBlockCipher(AESEngine());
  gcm.init(true, AEADParameters<CipherParameters>(KeyParameter(key), 128, iv, Uint8List(0)));
  return gcm.process(plaintext);
}

/// xeapi 反爬签名：HMAC-SHA256(signKey, timestamp + nonce) → base64
String nmXeapiSign(String timestamp, String nonce) =>
    base64.encode(_hmacSha256(utf8.encode(nmXeapiSignKey), utf8.encode('$timestamp$nonce')));

/// 由 ECDH 共享密钥 + 临时公钥派生 16 字节 AES 密钥（HKDF-SHA256 风格，对齐 deriveX25519AesKey）
Uint8List _deriveX25519AesKey(Uint8List sharedSecret, Uint8List ephemeralPublicKey) {
  final ikm = sharedSecret.isEmpty ? Uint8List(32) : sharedSecret;
  final prk = _hmacSha256(Uint8List(32), ikm);
  final info = Uint8List(33)..setAll(0, ephemeralPublicKey)..[32] = 1;
  return Uint8List.sublistView(_hmacSha256(prk, info), 0, 16);
}

/// 中间层变换：随机 XOR → base64 → 随机旋转（对齐 xeapiMidTransform）
Uint8List _xeapiMidTransform(Uint8List ciphertext) {
  final random = _randomBytes(16);
  final xored = Uint8List(ciphertext.length);
  for (var i = 0; i < ciphertext.length; i++) {
    xored[i] = ciphertext[i] ^ random[i & 0x0f];
  }
  final b64 = utf8.encode(base64.encode(xored));
  final rot = b64.isEmpty ? 0 : (random[0] & 0x0f) % b64.length;
  final out = Uint8List(16 + b64.length);
  out.setAll(0, random);
  out.setAll(16, b64.sublist(rot));
  out.setAll(16 + b64.length - rot, b64.sublist(0, rot));
  return out;
}

/// 用 X25519 ECDH + AES-GCM 封装动态密钥（S 字段，对齐 xeapiEncryptS）
Uint8List _xeapiEncryptS(Uint8List dynamicKey, NmXeapiPublicKey publicKeyState, String os) {
  final peerRaw = base64.decode(publicKeyState.publicKey);
  final ephemeralPrivate = _randomBytes(32);
  final ephemeralPublic = _x25519(ephemeralPrivate, _x25519BasePoint);
  final sharedSecret = _x25519(ephemeralPrivate, peerRaw);
  final aesKey = _deriveX25519AesKey(sharedSecret, ephemeralPublic);
  final iv = _randomBytes(12);
  final plaintext = utf8.encode('${base64.encode(dynamicKey)}|$os|${publicKeyState.sk ?? ''}');
  final encrypted = _aesGcmEncrypt(aesKey, iv, plaintext);
  final out = Uint8List(32 + 12 + encrypted.length);
  out.setAll(0, ephemeralPublic);
  out.setAll(32, iv);
  out.setAll(44, encrypted); // 密文含尾部 16 字节 GCM 认证标签
  return out;
}

/// 构造 xeapi 明文（JSON：body/queryString/...，对齐 buildXeapiPlaintext）
String _buildXeapiPlaintext(String uri, Map<String, dynamic> data, NmXeapiOptions options) {
  final fields = <String, String>{};
  final contentType = options.contentType ?? 'application/x-www-form-urlencoded;charset=utf-8';
  if (contentType.split(';').first.trim().toLowerCase() != 'application/x-www-form-urlencoded') {
    fields['contentType'] = contentType;
  }
  final method = (options.method ?? 'POST').toUpperCase();
  if (method != 'POST') fields['method'] = method;

  final uriObj = Uri.parse(uri);
  if (uriObj.hasQuery) fields['queryString'] = uriObj.query;

  final bodyData = Map<String, dynamic>.from(data)..remove('e_r');
  final form = Uri(queryParameters: bodyData.map((k, v) => MapEntry(k, '$v'))).query;
  fields['body'] = base64.encode(utf8.encode(form));

  fields['queryString'] =
      fields.containsKey('queryString') ? '${fields['queryString']}&e_r=true' : 'e_r=true';
  return jsonEncode(fields);
}

/// xeapi 加密 → { B, S, R } 三段 base64（对齐 crypto.ts xeapi）
({String B, String S, String R}) nmXeapi(
  String uri,
  Map<String, dynamic> data,
  NmXeapiOptions options,
) {
  final activeSessionKey =
      (options.sessionKey?.isNotEmpty ?? false) ? Uint8List.fromList(utf8.encode(options.sessionKey!)) : null;
  final activeSessionId = options.sessionId ?? '';
  final dynamicKey = activeSessionKey ?? _randomBytes(16);
  final plaintext = utf8.encode(_buildXeapiPlaintext(uri, data, options));

  // B = AES-ECB(dynamicKey, midTransform(AES-ECB(STATIC_KEY, plaintext)))
  final inner = _aesEcbBytes(plaintext, _xeapiStaticKey, encrypt: true);
  final mid = _xeapiMidTransform(inner);
  final b = _aesEcbBytes(mid, dynamicKey, encrypt: true);

  final s = _xeapiEncryptS(dynamicKey, options.publicKeyState, options.os ?? 'android');

  // R = AES-ECB(STATIC_KEY, `${version}|${有会话密钥时附带 sessionId}`)
  final rPlain =
      utf8.encode('${options.publicKeyState.version}|${activeSessionKey != null ? activeSessionId : ''}');
  final r = _aesEcbBytes(rPlain, _xeapiStaticKey, encrypt: true);

  return (
    B: base64.encode(b),
    S: base64.encode(s),
    R: base64.encode(r),
  );
}

/// xeapi 响应解密：AES-ECB(eapiKey) + 可选 gunzip + JSON（对齐 xeapiResDecrypt）
dynamic nmXeapiResDecrypt(Uint8List body) {
  final decrypted = _aesEcbBytes(body, utf8.encode(nmEapiKey), encrypt: false);
  final isGzip = decrypted.length >= 2 && decrypted[0] == 0x1f && decrypted[1] == 0x8b;
  final bytes = isGzip ? GZipCodec().decode(decrypted) : decrypted;
  return jsonDecode(utf8.decode(bytes));
}

/// 解密反爬接口返回的公钥包（对齐 xeapiDecryptPublicKey）
NmXeapiPublicKey nmXeapiDecryptPublicKey(String encryptedData) {
  final decrypted = _aesEcbBytes(base64.decode(encryptedData), _xeapiStaticKey, encrypt: false);
  final obj = jsonDecode(utf8.decode(decrypted)) as Map<String, dynamic>;
  return NmXeapiPublicKey(
    version: obj['version']?.toString() ?? '',
    publicKey: obj['publicKey']?.toString() ?? '',
    sk: obj['sk']?.toString(),
  );
}
