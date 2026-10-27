// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// 音质选择注册表：各源可选档位裁剪（`SourcePlatform.availableQualities`）。

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/netease/track.dart';
import 'package:archoera_music/services/source/source_platform.dart';

void main() {
  group('音质选择注册表', () {
    test('默认源（NT / 未知）为全档位', () {
      expect(sourcePlatform('netease').supportedQualities, audioQualityLevels);
      expect(
        sourcePlatform('netease').availableQualities(
          const Track(id: '1', title: 'x'),
        ),
        audioQualityLevels,
      );
      expect(
        sourcePlatform('__unknown__').availableQualities(
          const Track(id: '1', title: 'x'),
        ),
        audioQualityLevels,
      );
      expect(sourcePlatform('netease').maxQualityProvider(
        const Track(id: '1', title: 'x'),
      ), isNull);
    });

    test('KG：覆写裁剪（无品质 hash → 空档位）', () {
      const noHash = Track(
        id: '1',
        title: 'x',
        source: 'kugou',
        kugou: KugouTrackInfo(hash: 'h'),
      );
      expect(sourcePlatform('kugou').availableQualities(noHash), isEmpty);
      expect(
        sourcePlatform('kugou').availableQualities(
          const Track(id: '1', title: 'x'),
        ),
        audioQualityLevels,
      );
    });
  });
}
