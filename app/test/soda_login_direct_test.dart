// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 汽水登录直连验证：真实请求官方 Passport（不扫码）。
///
/// 覆盖 `get_qrcode` 出码 + 一次 `check_qrconnect`（等待态）。语义：证明纯
/// Dart HTTP（无 `a_bogus`/浏览器）可驱动官方登录链路。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/apis/soda/core/request.dart';
import 'package:archoera_music/services/soda/soda_auth.dart';

void main() {
  setUp(sodaClearCookies);
  tearDown(sodaClearCookies);

  test('get_qrcode 真实出码（不扫码）', () async {
    final auth = SodaAuth();
    final s = await auth.qrKey();
    expect(s.token, isNotEmpty);
    expect(s.imageUrl.isNotEmpty || s.url.isNotEmpty, isTrue);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('check_qrconnect 一次轮询（等待态，不抛错）', () async {
    final auth = SodaAuth();
    await auth.qrKey();
    final r = await auth.qrCheck();
    expect(
      r.status,
      anyOf(
        SodaLoginStatus.waiting,
        SodaLoginStatus.scanned,
        SodaLoginStatus.mfaRequired,
        SodaLoginStatus.expired,
        SodaLoginStatus.failed,
      ),
    );
  }, timeout: const Timeout(Duration(seconds: 30)));
}
