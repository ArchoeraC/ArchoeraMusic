// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// KG 加密 / 签名单测（**不联网**）：签名、MID、RSA、AES 与 KRC 解码往返。
///
/// 真实链路用例已移除：无登录 cookie 时多数曲目取不到可播直链，出口/风控
/// 差异还会变成假红或长时间等待。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archoera_music/services/kugou/kugou_crypto.dart';
import 'package:archoera_music/services/kugou/kugou_parse.dart' show decodeKrc;
import 'package:flutter_test/flutter_test.dart';

void main() {
  // ── 加密 / 签名单元测试 ──────────────────────────────────────────

  test('signatureAndroidParams 输出 32 位 hex', () {
    final sig = kgSignature({'mid': '12345', 'appid': 1005, 'dfid': 'abc'});
    expect(sig, matches(RegExp(r'^[0-9a-f]{32}$')));
  });

  test('signKey 输出 32 位 hex（与 TS 实现同构）', () {
    const hash = 'dd11d3a1e3ce4e38a81aa7f5650c3b87';
    // 与 node `signKey(hash, mid, userid, appid)` 同构：
    // md5(hash + keySalt + appid + mid + userid)
    expect(
      kgSignKey(hash, '12345', 0, 1005, salt: kgKeySalt),
      kgMd5('${hash}57ae12eb6890223e355ccfcb74edf70d1005123450'),
    );
    // lite 盐值：登录态 userid 注入 signKey
    expect(
      kgSignKey(hash, '12345', 7, 3116, salt: kgLiteKeySalt),
      kgMd5('${hash}185672dd44712f60bb1736df5a377e823116123457'),
    );
  });

  test('signatureWeb 输出 32 位 hex（登录接口签名）', () {
    final sig = kgSignatureWeb({
      'plat': 4,
      'appid': 3116,
      'srcappid': 2919,
      'qrcode': 'abc',
    });
    expect(sig, matches(RegExp(r'^[0-9a-f]{32}$')));
    // 与 KuGouMusicApi signatureWebParams 同构：salt+排序k=v+salt
    const str =
        'NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt'
        'appid=3116plat=4qrcode=abcsrcappid=2919'
        'NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt';
    expect(sig, kgMd5(str));
  });

  test('calculateMid 为十进制大整数', () {
    final mid = kgCalcMid(kgRandomString(16));
    expect(mid, isNotEmpty);
    // 十进制数字串（MD5 hex 视作 16 进制大整数 → 十进制）
    expect(BigInt.tryParse(mid), isNotNull);
  });

  test('RSA-PKCS1 加密输出 hex（对齐 rsaEncrypt2）', () {
    final hex = kgRsaPkcs1EncryptHex(
      jsonEncode({'aes': 'a1b2c3', 'uid': 0, 'token': ''}),
    );
    expect(hex, matches(RegExp(r'^[0-9a-f]+$')));
    expect(hex.length, 256); // 1024bit → 128 字节 → 256 hex
  });

  test('AES-CBC 加解密往返（playlistAes 系列）', () {
    final key = kgRandomString(6).toLowerCase();
    final cipher = kgAesEncryptBase64('{"a":1}', key);
    expect(cipher, isNotEmpty);
    final plain = kgAesDecryptString(cipher, key);
    expect(jsonDecode(plain), {'a': 1});
  });

  // ── KRC 解码往返（构造 → 加密 → decodeKrc → 断言） ──────────────

  test('KRC 解码：构造密文往返还原', () {
    const krcKey = <int>[
      0x40, 0x47, 0x61, 0x77, 0x5e, 0x32, 0x74, 0x47, //
      0x51, 0x36, 0x31, 0x2d, 0xce, 0xd2, 0x6e, 0x69,
    ];
    const raw =
        '[id:\$Kugou]\n'
        '[ti:小苹果]\n'
        '[ar:筷子兄弟]\n'
        '[0,3000]<0,100,0>小<100,200,0>苹<200,300,0>果\n'
        '[3000,5000]<0,200,0>我<200,300,0>们\n';
    final text = utf8.encode(raw);
    // 真实格式：先 deflate，再对压缩字节 XOR
    final deflated = ZLibCodec().encode(text);
    final xored = Uint8List(deflated.length);
    for (var i = 0; i < deflated.length; i++) {
      xored[i] = deflated[i] ^ krcKey[i % 16];
    }
    final payload = Uint8List(4 + xored.length)..setAll(4, xored);

    final parsed = decodeKrc(base64.encode(payload));
    expect(parsed.lrc, contains('小苹果'));
    expect(parsed.lrc, contains('我们'));
    expect(parsed.krc, contains('<0,100>小'));
    expect(parsed.lrc, isNot(contains('<'))); // 行级 LRC 无字级时间
  });
}
