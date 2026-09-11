// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 防伪签名回归：官方负载验签通过；篡改负载/换公钥一律失败；缺失不抛异常。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/app/watermark.dart';

void main() {
  test('官方负载验签通过', () {
    expect(archoeraWatermark, 'ARCHOERA DESIGNED');
    expect(archoeraWatermarkPayload, contains('ARCHOERA DESIGNED'));
    expect(verifyArchoeraWatermark(), isTrue);
  });

  test('篡改负载后验签失败（无官方私钥无法伪造）', () {
    expect(
      verifyWatermarkData(
        payload: 'ARCHOERA DESIGNED|ArchoeraMusic|EvilFork|MIT',
        pubKeyHex: archoeraWatermarkPubKeyHex,
        sigDerHex: archoeraWatermarkSigDerHex,
      ),
      isFalse,
    );
  });

  test('非法/他人公钥验签失败（不抛异常）', () {
    expect(
      verifyWatermarkData(
        payload: archoeraWatermarkPayload,
        pubKeyHex: '04${'00' * 64}',
        sigDerHex: archoeraWatermarkSigDerHex,
      ),
      isFalse,
    );
    expect(
      verifyWatermarkData(
        payload: archoeraWatermarkPayload,
        pubKeyHex: archoeraWatermarkPubKeyHex,
        sigDerHex: 'not-hex',
      ),
      isFalse,
    );
  });
}
