// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 封面内存治理测试：
/// - 封面 ImageCache 上限**恒有界**（旧版「无上限」写入的 0 / 缺失一律回落最小值）；
/// - [coverImageProvider] 按所需最大位图在解码阶段降采样（[ResizeImage]）。
library;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/stores/app_prefs.dart';
import 'package:archoera_music/widgets/list/cover_image.dart';

void main() {
  group('封面缓存上限恒有界', () {
    test('缺失 → 最小值', () {
      expect(AppPrefs().imageCacheLimitMiB, imageCacheLimitMinMiB);
    });

    test('旧版「无上限」写入的 0 / 负数 → 回落最小值', () {
      expect(
        AppPrefs().copyWithPreset(imageCacheLimitMiB: 0).imageCacheLimitMiB,
        imageCacheLimitMinMiB,
      );
      expect(
        AppPrefs().copyWithPreset(imageCacheLimitMiB: -8).imageCacheLimitMiB,
        imageCacheLimitMinMiB,
      );
    });

    test('超出上限 → 钳到最大值；范围内 → 原值', () {
      expect(
        AppPrefs()
            .copyWithPreset(imageCacheLimitMiB: 1 << 20)
            .imageCacheLimitMiB,
        imageCacheLimitMaxMiB,
      );
      expect(
        AppPrefs().copyWithPreset(imageCacheLimitMiB: 64).imageCacheLimitMiB,
        64,
      );
    });
  });

  group('coverImageProvider 按需降采样', () {
    test('空地址 / 本地文件不存在 → null', () {
      expect(coverImageProvider(null), isNull);
      expect(coverImageProvider(''), isNull);
      expect(
        coverImageProvider('/no/such/cover/__archoera_missing__.jpg'),
        isNull,
      );
    });

    test('网络图：给了目标尺寸 → ResizeImage（不放大）', () {
      final p = coverImageProvider(
        'https://example.com/a.jpg',
        decodeWidth: 128,
      );
      expect(p, isA<ResizeImage>());
      final r = p! as ResizeImage;
      expect(r.imageProvider, isA<NetworkImage>());
      expect(r.width, 128);
      expect(r.allowUpscaling, isFalse);
    });

    test('网络图：未给尺寸（或 0）→ 原样 NetworkImage（协议相对补 https）', () {
      final p = coverImageProvider('//example.com/a.jpg');
      expect(p, isA<NetworkImage>());
      expect((p! as NetworkImage).url, 'https://example.com/a.jpg');

      expect(coverImageProvider('https://e.com/b.jpg', decodeWidth: 0),
          isA<NetworkImage>());
    });
  });
}
