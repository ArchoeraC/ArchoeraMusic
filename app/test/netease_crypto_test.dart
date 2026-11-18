// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// NT 加密原语单测（**不联网**）：weapi / eapi / RSA 输出格式。
///
/// 真实云端直连用例已移除（无登录 cookie 时多数曲目取不到可播直链，
/// 且出口/风控差异会变成假红）。加密原语来自 apis 包
/// （app/lib/core/apis/netease/，纯 Dart 直连）。
library;

import 'package:archoera_music/apis/netease/core/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('weapi 输出结构', () {
    final enc = nmWeapi({
      's': 'test',
      'type': 1,
      'limit': 1,
      'offset': 0,
      'total': true,
    });
    expect(enc.params, isNotEmpty);
    expect(enc.params, contains(RegExp(r'^[A-Za-z0-9+/=]+$'))); // base64
    expect(enc.encSecKey, matches(RegExp(r'^[0-9a-f]{256}$'))); // 256 位 hex
  });

  test('eapi 输出为 32+ 大写 hex', () {
    final out = nmEapi('/api/cloudsearch/pc', {'s': 'test', 'header': {}});
    expect(out, matches(RegExp(r'^[0-9A-F]+$')));
    expect(out.length % 32, 0);
  });

  test('RSA 裸加密输出定长 256 hex', () {
    final hex = nmRsaEncrypt('secret-key-reversed');
    expect(hex, matches(RegExp(r'^[0-9a-f]{256}$')));
  });
}
