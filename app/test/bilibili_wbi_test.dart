// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/apis/bilibili/core/wbi.dart';
import 'package:archoera_music/apis/bilibili/core/types.dart';

void main() {
  group('Bilibili WBI', () {
    test('published vector', () {
      final query = bilibiliWbiQuery(
        params: const {'foo': '114', 'bar': '514', 'zab': '1919810'},
        imageKey: '7cd084941338484aae1ad9425b84077c',
        subKey: '4932caff0ff746eab6f01bf08b70ac45',
        timestamp: 1702204169,
      );
      expect(
        query,
        'bar=514&foo=114&wts=1702204169&zab=1919810&'
        'w_rid=8f6f2b5b3d485fe1886cec6a0be8c5d4',
      );
    });

    test('invalid keys are rejected', () {
      expect(
        bilibiliWbiQuery(
          params: const {'a': '1'},
          imageKey: 'bad',
          subKey: 'bad',
          timestamp: 1,
        ),
        isNull,
      );
    });
  });

  group('Bilibili model helpers', () {
    test('duration and URL normalization', () {
      expect(bilibiliDurationMs('03:20'), 200000);
      expect(bilibiliDurationMs('1:02:03'), 3723000);
      expect(bilibiliDurationMs(12), 12000);
      expect(
        bilibiliHttpsUrl('//i0.hdslb.com/a.jpg')?.startsWith('https://'),
        isTrue,
      );
      expect(
        bilibiliHttpsUrl('http://i0.hdslb.com/a.jpg')?.startsWith('https://'),
        isTrue,
      );
      expect(bilibiliHttpsUrl('file:///tmp/a.jpg'), isNull);
    });

    test('BV validation', () {
      expect(isBilibiliBvid('BV1Cjxy68EKv'), isTrue);
      expect(isBilibiliBvid('BV123'), isFalse);
    });
  });
}
