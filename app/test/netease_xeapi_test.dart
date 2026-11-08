// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 回归：xeapi CSR 协议（对齐 SPlayer-Next 2026-10-10 `7c2aea7d46`）。
///
/// 上游该次提交修正了三处与服务端解密强相关的细节：
///  - 中间层变换按**原始字节**旋转（旧实现先转 base64 再旋转）；
///  - form-urlencoded 正文放 `content`（旧实现一律 base64 放 `body`）；
///  - 密文字段由 `B`（base64）改为 `C`（无填充 base64url）。
/// 同时公钥端点迁到 `/api/bsr/sk/get`、客户端版本升到 9.5.61。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archoera_music/apis/netease/core/crypto.dart';
import 'package:archoera_music/apis/netease/core/xeapi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';

/// 与 crypto.dart 的 xeapi 静态密钥一致。
final Uint8List _staticKey = Uint8List.fromList(<int>[
  0xab, 0x1d, 0x5a, 0x43, 0x0f, 0x6b, 0xb0, 0x4a,
  0x3f, 0x01, 0xe8, 0x1d, 0xdd, 0x72, 0xbd, 0x91,
  0x6d, 0x5c, 0xe5, 0x91, 0x24, 0x8a, 0xc1, 0x28,
  0x71, 0x48, 0x06, 0xd7, 0xf8, 0xfb, 0x1b, 0x84,
]);

Uint8List _aesEcbDecrypt(Uint8List key, Uint8List input) {
  final cipher = PaddedBlockCipherImpl(
    PKCS7Padding(),
    ECBBlockCipher(AESEngine()),
  );
  cipher.init(
    false,
    PaddedBlockCipherParameters<CipherParameters, CipherParameters>(
      KeyParameter(key),
      null,
    ),
  );
  return cipher.process(input);
}

Uint8List _decodeBase64UrlNoPadding(String value) {
  final padded = value.padRight(value.length + (4 - value.length % 4) % 4, '=');
  return base64Url.decode(padded);
}

NmXeapiPublicKey _testKey() => NmXeapiPublicKey(
  version: 'test-version',
  // 仅用于生成 S 段；这里用 X25519 基点（u=9）作为对端公钥。
  publicKey: base64.encode(Uint8List(32)..[0] = 9),
  sk: 'test-sk',
);

/// 用 [sessionKey] 解开 C，再逆向 XOR/旋转，返回 xeapi 明文 JSON。
Map<String, dynamic> _unpackC(String c, Uint8List sessionKey) {
  final transformed = _aesEcbDecrypt(sessionKey, _decodeBase64UrlNoPadding(c));
  final random = transformed.sublist(0, 16);
  final rotated = transformed.sublist(16);
  final rotation = (random[0] & 0x0f) % rotated.length;
  final xored = Uint8List.fromList(<int>[
    ...rotated.sublist(rotated.length - rotation),
    ...rotated.sublist(0, rotated.length - rotation),
  ]);
  final ciphertext = Uint8List.fromList(<int>[
    for (var i = 0; i < xored.length; i++) xored[i] ^ random[i & 0x0f],
  ]);
  return jsonDecode(utf8.decode(_aesEcbDecrypt(_staticKey, ciphertext)))
      as Map<String, dynamic>;
}

void main() {
  test('xeapi：C 为无填充 base64url，form 正文走 content', () {
    final sessionKey = Uint8List.fromList(
      utf8.encode('12345678901234567890123456789012'),
    );
    final encrypted = nmXeapi(
      '/api/song?source=player',
      {'id': '123', 'text': '中文', 'e_r': false},
      NmXeapiOptions(
        publicKeyState: _testKey(),
        sessionKey: utf8.decode(sessionKey),
        sessionId: 'session',
      ),
    );

    expect(encrypted.C, matches(RegExp(r'^[A-Za-z0-9_-]+$')));
    expect(encrypted.S, isNotEmpty);
    expect(encrypted.R, isNotEmpty);

    final fields = _unpackC(encrypted.C, sessionKey);
    expect(fields['queryString'], 'source=player&e_r=true');
    expect(fields['content'], 'id=123&text=%E4%B8%AD%E6%96%87');
    expect(fields.containsKey('body'), isFalse);

    final metadata = utf8.decode(
      _aesEcbDecrypt(_staticKey, base64.decode(encrypted.R)),
    );
    expect(metadata, 'test-version|session');
  });

  test('xeapi：空正文不添加 content/body', () {
    final sessionKey = Uint8List.fromList(
      utf8.encode('12345678901234567890123456789012'),
    );
    final encrypted = nmXeapi(
      '/api/song',
      {'e_r': true},
      NmXeapiOptions(
        publicKeyState: _testKey(),
        sessionKey: utf8.decode(sessionKey),
      ),
    );
    final fields = _unpackC(encrypted.C, sessionKey);
    expect(fields, {'queryString': 'e_r=true'});
  });

  test('xeapi：登出后的迟到会话密钥不能恢复', () {
    final old = nmGetXeapiSession();
    nmResetXeapiKey();
    nmUpdateXeapiSession('old-id', 'old-key', old.generation);
    expect(nmGetXeapiSession().sessionId, isEmpty);
    expect(nmGetXeapiSession().sessionKey, isEmpty);

    final current = nmGetXeapiSession().generation;
    nmUpdateXeapiSession('new-id', 'new-key', current);
    expect(nmGetXeapiSession().sessionId, 'new-id');
    expect(nmGetXeapiSession().sessionKey, 'new-key');
  });
}
