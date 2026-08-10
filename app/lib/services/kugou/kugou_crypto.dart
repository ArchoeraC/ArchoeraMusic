/// 酷狗 API 加解密层（Dart 移植）
///
/// 对齐 KuGouMusicApi util/{crypto,helper,util}.js：
/// - register_dev：AES-128-CBC（key/iv 来自 md5(secretKey) 分段）+ RSA-PKCS1v1.5
/// - /v5/url：signature = md5(salt + 排序参数串 + data + salt)、key = md5(hash + salt + ...)
///
/// 加密基础库用 pointycastle（AES/RSA）+ Dart 内置 BigInt。
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/export.dart';

/// android 签名盐值（signatureAndroidParams 标准版）
const kgSignSalt = 'OIlwieks28dk2k092lksi2UIkp';

/// /v5/url 的 key 签名盐值（signKey 标准版）
const kgKeySalt = '57ae12eb6890223e355ccfcb74edf70d';

/// android 签名盐值（signatureAndroidParams 概念版 lite）
const kgLiteSignSalt = 'LnT6xpN3khm36zse0QzvmgTZ3waWdRSA';

/// /v5/url 的 key 签名盐值（signKey 概念版 lite）
const kgLiteKeySalt = '185672dd44712f60bb1736df5a377e82';

/// 概念版 lite 的 appid / clientver（MoeKoeMusic --platform=lite）
const kgLiteAppid = 3116;
const kgLiteClientver = 11440;

/// 来源 appid（扫码登录必需，KuGouMusicApi config.json srcappid=2919）
const kgSrcAppid = 2919;

/// web 版签名盐值（signatureWebParams，扫码登录等 web 接口）
const kgWebSignSalt = 'NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt';

/// register_dev RSA 公钥（标准版，1024bit，SPKI PEM）
const kgPublicKeyPem = '''-----BEGIN PUBLIC KEY-----
MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDIAG7QOELSYoIJvTFJhMpe1s/gbjDJX51HBNnEl5HXqTW6lQ7LC8jr9fWZTwusknp+sVGzwd40MwP6U5yDE27M/X1+UR4tvOGOqp94TJtQ1EPnWGWXngpeIW5GxoQGao1rmYWAu6oi1z9XkChrsUdC6DJE5E221wf/4WLFxwAtRQIDAQAB
-----END PUBLIC KEY-----''';

/// register_dev RSA 公钥（概念版 lite，1024bit，SPKI PEM）
const kgLitePublicKeyPem = '''-----BEGIN PUBLIC KEY-----
MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDECi0Np2UR87scwrvTr72L6oO01rBbbBPriSDFPxr3Z5syug0O24QyQO8bg27+0+4kBzTBTBOZ/WWU0WryL1JSXRTXLgFVxtzIY41Pe7lPOgsfTCn5kZcvKhYKJesKnnJDNr5/abvTGf+rHG3YRwsCHcQ08/q6ifSioBszvb3QiwIDAQAB
-----END PUBLIC KEY-----''';

/// 随机字符串字符池（1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZ）
const _kgPool = '1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZ';

/// 生成随机字符串（dfid 24 位、device uuid 等）
String kgRandomString(int len) {
  final rng = Random.secure();
  return String.fromCharCodes(
    List.generate(len, (_) => _kgPool.codeUnitAt(rng.nextInt(36))),
  );
}

/// MD5 hex（小写）
String kgMd5(String data) => crypto.md5.convert(utf8.encode(data)).toString();

/// 计算设备 MID：md5(guid) hex 视作 16 进制大整数 → 十进制字符串
/// 对齐 KuGouMusicApi util.calculateMid
String kgCalcMid(String guid) {
  final hex = crypto.md5.convert(utf8.encode(guid)).toString();
  return BigInt.parse('0x$hex').toString();
}

// ─── AES-128-CBC（playlistAesEncrypt / playlistAesDecrypt） ─────────────

/// AES-128-CBC 加密：key = md5(secretKey) 前 16 字符（ASCII 字节），
/// iv = 后 16 字符。返回 base64 密文。对齐 playlistAesEncrypt。
String kgAesEncryptBase64(String plain, String secretKey) {
  final key = kgAesKeyIv(secretKey);
  final block = CBCBlockCipher(AESEngine()) as BlockCipher;
  final cipher = PaddedBlockCipherImpl(PKCS7Padding(), block);
  cipher.init(
    true,
    PaddedBlockCipherParameters<CipherParameters, CipherParameters>(
      ParametersWithIV<CipherParameters>(
        KeyParameter(utf8.encode(key.$1)),
        utf8.encode(key.$2),
      ),
      null,
    ),
  );
  return base64.encode(cipher.process(utf8.encode(plain)));
}

/// AES-128-CBC 解密 → utf8 文本。对齐 playlistAesDecrypt。
String kgAesDecryptString(String cipherB64, String secretKey) {
  final key = kgAesKeyIv(secretKey);
  final block = CBCBlockCipher(AESEngine()) as BlockCipher;
  final cipher = PaddedBlockCipherImpl(PKCS7Padding(), block);
  cipher.init(
    false,
    PaddedBlockCipherParameters<CipherParameters, CipherParameters>(
      ParametersWithIV<CipherParameters>(
        KeyParameter(utf8.encode(key.$1)),
        utf8.encode(key.$2),
      ),
      null,
    ),
  );
  final out = cipher.process(base64.decode(cipherB64));
  return utf8.decode(out);
}

/// 由 secretKey 派生 (key, iv)：md5 后各取 16 字符（对齐 playlistAes 系列）。
(String, String) kgAesKeyIv(String secretKey) {
  final digest = kgMd5(secretKey);
  return (digest.substring(0, 16), digest.substring(16, 32));
}

// ─── RSA-PKCS1v1.5（rsaEncrypt2） ──────────────────────────────────────

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

(BigInt, BigInt)? _kgRsaKey;
String? _kgRsaKeyPem;

/// 从 SPKI PEM 提取 RSA 模数 n 与指数 e
(BigInt, BigInt) _parseKgPublicKey(String pem) {
  if (_kgRsaKey != null && _kgRsaKeyPem == pem) return _kgRsaKey!;
  final b64 = pem.replaceAll(
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
  _kgRsaKey = key;
  _kgRsaKeyPem = pem;
  return key;
}

/// RSA-PKCS1v1.5 加密 → 小写 hex。对齐 rsaEncrypt2（node-forge 默认 padding）。
/// [pem] 可传 lite 公钥。
String kgRsaPkcs1EncryptHex(String jsonStr, {String pem = kgPublicKeyPem}) {
  final (n, e) = _parseKgPublicKey(pem);
  final enc = PKCS1Encoding(RSAEngine());
  enc.init(true, PublicKeyParameter<RSAPublicKey>(RSAPublicKey(n, e)));
  final out = enc.process(utf8.encode(jsonStr));
  return out.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// raw RSA 加密（零填充）→ 大写 hex。对齐 cryptoRSAEncrypt + rsaRawEncrypt
/// （user_detail/get_my_info 用）：数据左对齐补 0 到模长 128 字节，modPow，
/// hex padStart 256。与 [kgRsaPkcs1EncryptHex]（PKCS1）不同，勿混用。
String kgRsaRawEncryptHex(String jsonStr, {String pem = kgLitePublicKeyPem}) {
  final (n, e) = _parseKgPublicKey(pem);
  final data = utf8.encode(jsonStr);
  final padded = Uint8List(128);
  padded.setAll(0, data);
  final enc = RSAEngine();
  enc.init(true, PublicKeyParameter<RSAPublicKey>(RSAPublicKey(n, e)));
  final out = enc.process(padded);
  return out.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
}

// ─── 请求签名（signature / signKey） ─────────────────────────────────────

/// android 签名：md5(salt + 排序 key=value 串 + data + salt)。
/// [data] 为 POST body（register_dev 传 AES 密文；GET 为空）。
/// [salt] 默认标准版，可传 [kgLiteSignSalt]。
String kgSignature(
  Map<String, dynamic> params, {
  String data = '',
  String salt = kgSignSalt,
}) {
  final keys = params.keys.toList()..sort();
  final buf = StringBuffer();
  for (final k in keys) {
    final v = params[k];
    buf.write('$k=${v is Map ? jsonEncode(v) : v}');
  }
  return kgMd5('$salt${buf.toString()}$data$salt');
}

/// /v5/url 的 key 参数：md5(hash + keySalt + appid + mid + userid)。
/// [salt] 默认标准版，可传 [kgLiteKeySalt]。
String kgSignKey(
  String hash,
  String mid,
  int userid,
  int appid, {
  String salt = kgKeySalt,
}) =>
    kgMd5('$hash$salt$appid$mid$userid');

/// web 签名：md5(salt + 排序 key=value 串 + salt)。
/// 与 android 版（[kgSignature]）区别：盐值不同且不含请求体 data，
/// 用于扫码登录（login_qr_key / login_qr_check）等 web 接口。
String kgSignatureWeb(Map<String, dynamic> params) {
  final keys = params.keys.toList()..sort();
  final buf = StringBuffer();
  for (final k in keys) {
    final v = params[k];
    buf.write('$k=${v is Map ? jsonEncode(v) : v}');
  }
  return kgMd5('$kgWebSignSalt${buf.toString()}$kgWebSignSalt');
}

/// 参数密钥签名（signParamsKey，对齐 KuGouMusicApi helper.signParamsKey）：
/// md5(appid + 盐 + clientver + data)。top_playlist / artist_audios 等
/// 模块把 `key` 放进请求体/参数。默认 lite（appid 3116 / clientver 11440 /
/// [kgLiteSignSalt]），与 MoeKoeMusic --platform=lite 一致。
String kgSignParamsKey(
  String data, {
  int? appid,
  int? clientver,
  String salt = kgLiteSignSalt,
}) =>
    kgMd5('${appid ?? kgLiteAppid}$salt${clientver ?? kgLiteClientver}$data');
