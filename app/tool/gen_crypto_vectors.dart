/// 生成 downloader 对拍基准向量（Dart 真实实现 → Rust 单测硬编码期望值）。
///
/// 用法（在 app/ 目录下；"Running build hooks..." 是 build.dart 钩子输出，
/// 混进 stdout 需用 sed 剥离）：
///   dart run tool/gen_crypto_vectors.dart 2>/dev/null \
///     | sed 's/Running build hooks\.\.\.//g' > core/downloader/tests/crypto_roundtrip.rs
///
/// 原则（对齐 §10 MVP0 对拍单测）：
/// - 确定性函数（md5/calcMid/aes/signature/signKey/rawRsa/weapi 固定 secret）
///   输出必须与 Rust **逐字符一致**。
/// - RSA-PKCS1v1.5 带随机填充 → 不可跨语言对拍，只做结构断言（长度/hex 合法性）。
/// - 生成脚本与 Rust 测试共用本文件为唯一数据源，改输入即全量重生成。
library;

import 'dart:convert';
import 'dart:io';

import 'package:archoera_music/apis/netease/core/config.dart';
import 'package:archoera_music/apis/netease/core/crypto.dart' as nm;
import 'package:archoera_music/services/kugou/kugou_crypto.dart' as kg;

// ─────────────────────────────────────────────────────────────
// Kugou 向量输入（固定，确定性）
// ─────────────────────────────────────────────────────────────

const _kgMd5Inputs = <String, String>{
  'hello world': '5eb63bbbe01eeed093cb22bb8f5acdc3',
  '': 'd41d8cd98f00b204e9800998ecf8427e',
  '8744B6EACB2AE3BF1A987886609AAE5B7557C3D0': '',
  '晴天': '',
  'LnT6xpN3khm36zse0QzvmgTZ3waWdRSAa=1b=2c=3': '',
};

const _kgMidInputs = <String>[
  '8744B6EACB2AE3BF1A987886609AAE5B7557C3D0',
  'abc123',
  '晴天测试',
  '5EB63BBBE01EEED093CB22BB8F5ACDC3',
  'KG_LITE_REGISTER_GUID_20260809',
];

const _kgAesCases = <(String, String)>[
  ('{"appid":3116,"dfid":"-","mid":"1000","part":1}', 'a1b2c3'),
  ('{"availableRamSize":4983533568,"brand":"Redmi"}', '123456'),
  ('{"uid":0,"token":"","aes":"a1b2c3"}', 'AbCdEf'),
];

const _kgSignKeyCases = <(String, String, int, int, String)>[
  ('8744b6eacb2ae3bf1a987886609aae5b7557c3d0', '1234567890', 0, 3116, kg.kgLiteKeySalt),
  ('e5c2a1b7f6d3e4f5a6b7c8d9e0f1a2b3', '999888777', 2919, 3116, kg.kgKeySalt),
  ('abc', 'mid-001', 100, 3116, kg.kgLiteKeySalt),
];

const _kgRsaRawCases = <String>[
  '{"aes":"a1b2c3","uid":0,"token":""}',
  '{"uid":123456,"token":"tok_xyz","aes":"secret"}',
];

const _kgSignatureCases = <(Map<String, String>, String, String)>[
  // register_dev 参数（真实流）
  (
    {
      'appid': '3116',
      'clienttime': '1723200000',
      'clientver': '11440',
      'dfid': '-',
      'mid': '1234567890',
      'part': '1',
      'p': 'abc',
      'platid': '1',
      'uuid': '-',
    },
    'AES_CIPHER_BODY',
    kg.kgLiteSignSalt,
  ),
  // v5/url 参数（真实流，含降级链常用字段）
  (
    {
      'appid': '3116',
      'clienttime': '1723200001',
      'clientver': '11440',
      'cmd': '26',
      'dfid': 'DFID_REAL',
      'hash': '8744b6eacb2ae3bf1a987886609aae5b7557c3d0',
      'key': 'KEY_MD5',
      'mid': '1234567890',
      'quality': '320',
      'signature': 'SIG_PLACEHOLDER',
      'uuid': '-',
    },
    '',
    kg.kgLiteSignSalt,
  ),
  // 标准版盐（android 标准流）
  (
    {'album_audio_id': '0', 'album_id': '0', 'behavior': 'play', 'pid': '411'},
    'BODY_STD',
    kg.kgSignSalt,
  ),
];

// ─────────────────────────────────────────────────────────────
// Netease 向量输入（固定，确定性）
// ─────────────────────────────────────────────────────────────

const _nmAesCases = <(String, String)>[
  ('{"id":"28948791","level":"standard"}', nmPresetKey),
  ('{"csrf_token":"","e_r":false}', '0CoJUm6Qyw8W8jud'),
  ('{"ids":"[12345]","level":"exhigh"}', 'secretKey16bytes'),
];

const _nmRsaCases = <String>[
  'abcdefghijklmnop',
  '0CoJUm6Qyw8W8jud',
  'a0b1c2d3e4f5',
];

const _weapiCases = <(Map<String, dynamic>, String)>[
  (
    {'id': '28948791', 'level': 'standard', 'csrf_token': '', 'e_r': false},
    'abcdefghijklmnop',
  ),
  (
    {'id': '28948791', 'level': 'lossless', 'csrf_token': '', 'e_r': false},
    '0123456789abcdef',
  ),
];

// ─────────────────────────────────────────────────────────────
// 输出：Rust 单测文件
// ─────────────────────────────────────────────────────────────

String _r(String s) => s.replaceAll('\\', '\\\\').replaceAll('"', '\\"');

String _signatureCaseRust((Map<String, String>, String, String) c) {
  final (params, data, salt) = c;
  final entries = params.entries
      .map((e) => '        params.insert("${_r(e.key)}".into(), "${_r(e.value)}".into());')
      .join('\n');
  return '''
    {
        let mut params = std::collections::BTreeMap::new();
$entries
        let expected = "${_r(kg.kgSignature(params, data: data, salt: salt))}";
        assert_eq!(kugou::kg_signature(&params, "${_r(data)}", "${_r(salt)}"), expected);
    }''';
}

String generate() {
  final b = StringBuffer();

  b.writeln('// ============================================================');
  b.writeln('// §10 MVP0 对拍单测：Kugou/Netease 签名 Rust ↔ Dart 字节级一致');
  b.writeln('//');
  b.writeln('// 本文件由 app/tool/gen_crypto_vectors.dart 自动生成，请勿手改！');
  b.writeln('// 重新生成：dart run tool/gen_crypto_vectors.dart > tests/crypto_roundtrip.rs');
  b.writeln('// ============================================================');
  b.writeln('');

  b.writeln('#[cfg(test)]');
  b.writeln('mod kugou_roundtrip {');
  b.writeln('    use archoera_downloader::crypto::kugou;');
  b.writeln('');

  // ── kg_md5 ──
  b.writeln('    /// kg_md5：与 Dart kgMd5 逐字符一致');
  b.writeln('    #[test]');
  b.writeln('    fn test_kg_md5() {');
  for (final e in _kgMd5Inputs.entries) {
    final out = kg.kgMd5(e.key);
    b.writeln('        assert_eq!(kugou::kg_md5("${_r(e.key)}"), "$out");');
  }
  b.writeln('    }');
  b.writeln('');

  // ── kg_calc_mid ──
  b.writeln('    /// kg_calc_mid：md5(guid) hex → BigInt 十进制字符串');
  b.writeln('    #[test]');
  b.writeln('    fn test_kg_calc_mid() {');
  for (final g in _kgMidInputs) {
    final out = kg.kgCalcMid(g);
    b.writeln('        assert_eq!(kugou::kg_calc_mid("${_r(g)}"), "$out");');
  }
  b.writeln('    }');
  b.writeln('');

  // ── kg_aes_encrypt_base64 ──
  b.writeln('    /// kg_aes_encrypt_base64：AES-128-CBC + PKCS7，key/iv 派生自 md5(secretKey)');
  b.writeln('    #[test]');
  b.writeln('    fn test_kg_aes_encrypt_base64() {');
  for (final (plain, sk) in _kgAesCases) {
    final out = kg.kgAesEncryptBase64(plain, sk);
    b.writeln('        assert_eq!(kugou::kg_aes_encrypt_base64("${_r(plain)}", "$sk"), "$out");');
  }
  b.writeln('    }');
  b.writeln('');

  // ── kg_aes roundtrip ──
  b.writeln('    /// kg_aes 解密回环：Rust 侧 encrypt → decrypt == 原文（自洽性）');
  b.writeln('    #[test]');
  b.writeln('    fn test_kg_aes_roundtrip() {');
  for (final (plain, sk) in _kgAesCases) {
    final cipher = kg.kgAesEncryptBase64(plain, sk);
    b.writeln('        let cipher = kugou::kg_aes_encrypt_base64("${_r(plain)}", "$sk");');
    b.writeln('        assert_eq!(cipher, "$cipher");');
    b.writeln('        assert_eq!(kugou::kg_aes_decrypt_string(&cipher, "$sk").unwrap(), "${_r(plain)}");');
  }
  b.writeln('    }');
  b.writeln('');

  // ── kg_signature ──
  b.writeln('    /// kg_signature：md5(salt + 排序 k=v 串 + data + salt)');
  b.writeln('    #[test]');
  b.writeln('    fn test_kg_signature() {');
  for (final c in _kgSignatureCases) {
    b.writeln(_signatureCaseRust(c));
  }
  b.writeln('    }');
  b.writeln('');

  // ── kg_sign_key ──
  b.writeln('    /// kg_sign_key：md5(hash + salt + appid + mid + userid)');
  b.writeln('    #[test]');
  b.writeln('    fn test_kg_sign_key() {');
  for (final (hash, mid, uid, appid, salt) in _kgSignKeyCases) {
    final out = kg.kgSignKey(hash, mid, uid, appid, salt: salt);
    b.writeln('        assert_eq!(kugou::kg_sign_key("${_r(hash)}", "$mid", $uid, $appid, "$salt"), "$out");');
  }
  b.writeln('    }');
  b.writeln('');

  // ── kg_rsa_raw_encrypt_hex ──
  b.writeln('    /// kg_rsa_raw_encrypt_hex：零填充 raw RSA → 大写 hex（确定性）');
  b.writeln('    #[test]');
  b.writeln('    fn test_kg_rsa_raw_encrypt_hex() {');
  for (final plain in _kgRsaRawCases) {
    final out = kg.kgRsaRawEncryptHex(plain, pem: kg.kgLitePublicKeyPem);
    b.writeln('        assert_eq!(kugou::kg_rsa_raw_encrypt_hex("${_r(plain)}", kugou::KG_LITE_PUBLIC_KEY_PEM), "$out");');
  }
  b.writeln('    }');
  b.writeln('');

  // ── kg_rsa_pkcs1 structure ──
  b.writeln('    /// kg_rsa_pkcs1_encrypt_hex：带随机填充，不可跨语言对拍 → 只做结构断言');
  b.writeln('    /// （1024bit 模长 → 密文恰为 128 字节 / 256 位 hex，且两次调用结果不同）');
  b.writeln('    #[test]');
  b.writeln('    fn test_kg_rsa_pkcs1_structure() {');
  b.writeln('        let plain = r#"{"aes":"a1b2c3","uid":0,"token":""}"#;');
  b.writeln('        let a = kugou::kg_rsa_pkcs1_encrypt_hex(plain, kugou::KG_LITE_PUBLIC_KEY_PEM);');
  b.writeln('        let b = kugou::kg_rsa_pkcs1_encrypt_hex(plain, kugou::KG_LITE_PUBLIC_KEY_PEM);');
  b.writeln('        assert_eq!(a.len(), 256, "RSA PKCS1 输出应为 256 位 hex");');
  b.writeln('        assert!(hex::decode(&a).is_ok(), "RSA PKCS1 输出应为合法 hex");');
  b.writeln('        assert_ne!(a, b, "PKCS1v1.5 随机填充：两次加密应不同");');
  b.writeln('    }');
  b.writeln('}');
  b.writeln('');

  b.writeln('#[cfg(test)]');
  b.writeln('mod netease_roundtrip {');
  b.writeln('    use archoera_downloader::crypto::netease;');
  b.writeln('');

  // ── nm_aes_cbc_base64 ──
  b.writeln('    /// nm_aes_cbc_base64：AES-128-CBC + PKCS7，固定 IV');
  b.writeln('    #[test]');
  b.writeln('    fn test_nm_aes_cbc_base64() {');
  for (final (text, key) in _nmAesCases) {
    final out = nm.nmAesCbcBase64(text, key);
    b.writeln('        assert_eq!(netease::nm_aes_cbc_base64("${_r(text)}", "$key"), "$out");');
  }
  b.writeln('    }');
  b.writeln('');

  // ── nm_rsa_encrypt ──
  b.writeln('    /// nm_rsa_encrypt：RSA_NO_PADDING（右对齐补 0）→ 256 位小写 hex（确定性）');
  b.writeln('    #[test]');
  b.writeln('    fn test_nm_rsa_encrypt() {');
  for (final plain in _nmRsaCases) {
    final out = nm.nmRsaEncrypt(plain);
    b.writeln('        assert_eq!(netease::nm_rsa_encrypt("${_r(plain)}"), "$out");');
  }
  b.writeln('    }');
  b.writeln('');

  // ── weapi_encrypt_with_secret ──
  b.writeln('    /// weapi_encrypt_with_secret：固定 secretKey 时 params/encSecKey 与 Dart 逐字符一致');
  b.writeln('    #[test]');
  b.writeln('    fn test_weapi_encrypt_with_secret() {');
  for (final (obj, sk) in _weapiCases) {
    final text = jsonEncode(obj);
    final first = nm.nmAesCbcBase64(text, nmPresetKey);
    final params = nm.nmAesCbcBase64(first, sk);
    final encSecKey = nm.nmRsaEncrypt(sk.split('').reversed.join());
    final jsonObj = obj.entries.map((e) => '"${e.key}": ${e.value is String ? '"${e.value}"' : e.value}').join(', ');
    b.writeln('        let obj = serde_json::json!({$jsonObj});');
    b.writeln('        let (params, enc_sec_key) = netease::weapi_encrypt_with_secret(&obj, "$sk");');
    b.writeln('        assert_eq!(params, "$params");');
    b.writeln('        assert_eq!(enc_sec_key, "$encSecKey");');
  }
  b.writeln('    }');
  b.writeln('}');
  b.writeln('');

  return b.toString();
}

void main() {
  stdout.write(generate());
}
